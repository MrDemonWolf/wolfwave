//
//  DiscordRPCService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-02-07.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import AppKit
import Foundation

// MARK: - Discord Playlist Style

/// How the current Apple Music playlist is surfaced in Discord Rich Presence.
///
/// Raw values are persisted in `UserDefaults`, so keep them stable across releases.
nonisolated enum DiscordPlaylistStyle: String, CaseIterable, Sendable {
    /// Playlist joins the artist on the activity's second line (`state`).
    case artistLine
    /// Playlist appears only in the small-icon hover tooltip (`assets.small_text`).
    case iconTooltip

    /// The style applied when no preference (or an unknown value) is stored.
    static let `default`: DiscordPlaylistStyle = .artistLine

    /// Resolves a stored raw value to a style, falling back to ``default``.
    static func resolved(from raw: String?) -> DiscordPlaylistStyle {
        guard let raw, let style = DiscordPlaylistStyle(rawValue: raw) else {
            return .default
        }
        return style
    }
}

// MARK: - Discord RPC Service

/// Manages Discord Rich Presence via the local IPC socket.
///
/// Connects to Discord's Unix domain socket at `$TMPDIR/discord-ipc-{0..9}`,
/// performs the RPC handshake, and sends SET_ACTIVITY commands to display
/// "Listening to Apple Music" on the user's Discord profile.
///
/// No bot token is required, only a Discord Application ID from the
/// Developer Portal, provided via `DISCORD_CLIENT_ID` in Config.xcconfig.
///
/// Thread Safety:
/// - Implemented as an `actor`. All mutable state runs on the actor's serial
///   executor.
/// - The *blocking* socket syscalls (`connect`, `read`, `write`, `setsockopt`)
///   do **not** run on the actor executor. They are dispatched onto a dedicated
///   serial `ipcQueue` and bridged back with `withCheckedContinuation`, so the
///   actor `await`s the result without parking its executor. A stalled handshake
///   or slow peer can no longer delay `updatePresence` or any other
///   actor-isolated call. The serial queue keeps the connection lifecycle
///   single-threaded. Each handshake or command write plus its matched reply is
///   one queue block, so actor reentrancy cannot interleave transactions or leave
///   replies unread. The blocking primitives are pure functions of an explicit
///   `fd` parameter and never touch actor state.
/// - State changes and resolved artwork URLs are published as `AsyncStream`s
///   on `stateChanges` and `artworkResolutions`. The streams are `nonisolated`
///   so consumers can iterate without an extra actor hop.
///
/// Reconnection:
/// - Automatically reconnects with exponential backoff when Discord restarts.
/// - Polls for Discord availability when not connected.
actor DiscordRPCService {

    // MARK: - Types

    /// IPC frame opcodes per Discord RPC spec.
    /// Widened from `private` to `internal` so the IPC extension
    /// (`DiscordRPCService+IPC.swift`) can reference it across files.
    enum Opcode: UInt32, Sendable {
        case handshake = 0
        case frame     = 1
        case close     = 2
        case ping      = 3
        case pong      = 4
    }

    /// Partial frame bytes shared by idle reads and command transactions.
    /// Access is confined to the serial IPC queue.
    nonisolated final class IPCReadBuffer: @unchecked Sendable {
        /// Bytes received but not yet consumed as a complete frame. A fresh
        /// buffer is installed for every new socket so stale bytes from a prior
        /// connection can never be parsed as a reply.
        var data = Data()
    }

    /// One-shot completion shared by every waiter for a descriptor teardown.
    ///
    /// A dispatch-source cancellation handler is the only code allowed to close
    /// a descriptor after the source is installed. Cancellation is asynchronous,
    /// so actor calls that retire the same connection await this completion
    /// instead of racing a second `close` against the source handler.
    nonisolated final class IPCDescriptorClose: @unchecked Sendable {
        private let lock = NSLock()
        private var isComplete = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        /// Marks the descriptor closed and resumes every current waiter.
        /// Idempotent: calls after the first are ignored. Waiters are resumed
        /// outside the lock.
        func complete() {
            lock.lock()
            guard !isComplete else {
                lock.unlock()
                return
            }
            isComplete = true
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        /// Suspends until ``complete()`` has run; returns immediately if it
        /// already has.
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isComplete {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        /// Test-only observation seam for deterministically proving that an
        /// actor call is suspended on descriptor teardown before another
        /// lifecycle intent interleaves.
        var hasWaiters: Bool {
            lock.withLock { !waiters.isEmpty }
        }
    }

    /// Connection state.
    enum ConnectionState: String, Sendable {
        case disconnected
        case connecting
        case connected
    }

    /// Why the last connection attempt did not reach ``ConnectionState/connected``.
    ///
    /// Before this existed, every one of these rendered as "Discord not
    /// running", which is asserted rather than observed and is often simply
    /// false: a rejected handshake or a sandbox-blocked socket both happen with
    /// Discord open on screen. The real reason was `Log.error` only.
    enum ConnectionFailure: String, Sendable {
        /// No attempt has failed, or a later attempt succeeded.
        case none
        /// No IPC socket exists in any candidate directory. Discord is closed.
        case notRunning
        /// A socket was found but Discord refused the handshake.
        case handshakeRejected
        /// The socket could not be reached at all: no temp directory resolved,
        /// or the sandbox denied it. Not something the user can fix by
        /// restarting Discord.
        case socketUnavailable
        /// This build shipped without a Discord Application ID.
        case notConfigured
    }

    /// Payload yielded by ``artworkResolutions`` when artwork resolves for a track.
    ///
    /// `track` / `artist` identify the song the lookup was for, so a consumer
    /// can drop a resolution that arrives after the track already changed.
    struct ArtworkResolution: Sendable, Equatable {
        let url: String
        let track: String
        let artist: String
    }

    // MARK: - Streams (nonisolated)

    /// Connection-state transitions, yielded whenever ``state`` changes.
    ///
    /// Consumers iterate via `for await newState in service.stateChanges`.
    nonisolated let stateChanges: AsyncStream<ConnectionState>
    /// Producer side of ``stateChanges``; finished in `deinit`.
    private nonisolated let stateContinuation: AsyncStream<ConnectionState>.Continuation

    /// Track artwork URLs, yielded once `ArtworkService` resolves the lookup.
    ///
    /// Consumers iterate via `for await resolution in service.artworkResolutions`.
    nonisolated let artworkResolutions: AsyncStream<ArtworkResolution>
    /// Producer side of ``artworkResolutions``; finished in `deinit`.
    private nonisolated let artworkContinuation: AsyncStream<ArtworkResolution>.Continuation

    // MARK: - Properties

    /// Lock-guarded mirror of ``state`` for nonisolated reads.
    private nonisolated let _stateSnapshot = Atomic<ConnectionState>(.disconnected)

    /// Latest connection state, safe to read synchronously from any thread.
    /// Mirrors ``state``; updated whenever the actor mutates `state`.
    nonisolated var stateSnapshot: ConnectionState {
        _stateSnapshot.value
    }

    /// Lock-guarded mirror of ``lastFailure`` for nonisolated reads.
    private nonisolated let _failureSnapshot = Atomic<ConnectionFailure>(.none)

    /// Why the last attempt failed, safe to read synchronously from any thread.
    nonisolated var failureSnapshot: ConnectionFailure {
        _failureSnapshot.value
    }

    /// Why the last connection attempt failed. Cleared on a successful connect
    /// so a stale reason cannot outlive the problem.
    var lastFailure: ConnectionFailure = .none {
        didSet {
            guard oldValue != lastFailure else { return }
            _failureSnapshot.set(lastFailure)
        }
    }

    /// Test seam: sets ``lastFailure`` from outside the actor so the
    /// ``failureSnapshot`` mirror can be exercised deterministically.
    ///
    /// Production code never calls this. The IPC extension shares this actor
    /// and assigns ``lastFailure`` directly.
    func recordFailure(_ failure: ConnectionFailure) {
        lastFailure = failure
    }

    /// Current connection state. Publishes to ``stateChanges`` on each transition
    /// and mirrors into ``stateSnapshot`` for nonisolated reads.
    ///
    /// Setter widened from `private(set)` to `internal` so the IPC extension
    /// (`DiscordRPCService+IPC.swift`) can transition it across files.
    var state: ConnectionState = .disconnected {
        didSet {
            guard oldValue != state else { return }
            _stateSnapshot.set(state)
            stateContinuation.yield(state)
        }
    }

    /// Discord Application ID resolved from Info.plist / environment.
    /// Widened from `private` for `DiscordRPCService+IPC.swift`.
    let clientID: String

    /// File descriptor for the connected Unix domain socket, or -1.
    /// Widened from `private` for `DiscordRPCService+IPC.swift`.
    var socketFD: Int32 = -1

    /// Monotonic token bumped on every disconnect/teardown.
    ///
    /// `connectIfNeeded` captures this before awaiting the off-actor
    /// `openIPCSocket` hop. If a `setEnabled(false)` (or any other teardown)
    /// lands during that await, the generation changes; the connect then closes
    /// the just-opened fd on ``ipcQueue`` and bails without committing
    /// `socketFD`/`state`, so an in-flight connect can never win after a disable.
    /// Widened from `private` for `DiscordRPCService+IPC.swift`.
    var connectionGeneration: UInt64 = 0

    /// Dedicated serial queue for the blocking socket syscalls.
    ///
    /// `connect`, `read`, `write`, and `setsockopt` block the calling thread.
    /// Running them here (instead of on the actor's serial executor) keeps a
    /// stalled handshake or slow peer from parking the actor. The queue is
    /// serial, so the connection lifecycle stays single-threaded. There is
    /// never concurrent access to `socketFD` from two IPC operations at once.
    /// Widened from `private` for `DiscordRPCService+IPC.swift`.
    nonisolated let ipcQueue = DispatchQueue(label: "com.mrdemonwolf.wolfwave.discord-ipc")
    /// Socket opener injection used to reproduce connect/disable races without
    /// touching a real Discord socket.
    nonisolated let ipcSocketOpener: @Sendable (String, Int) -> Int32
    /// Descriptor closer injection used to prove exactly-once teardown and fd
    /// reuse safety without weakening production ownership rules.
    nonisolated let ipcSocketCloser: @Sendable (Int32) -> Void

    /// Whole-transaction timeout. One monotonic deadline derived from this value
    /// covers the command write, every frame header/body read, PONG writes, and
    /// the complete unmatched-frame drain.
    nonisolated let ipcTransactionTimeoutNanoseconds: UInt64

    /// Optional test observer called immediately after work is submitted to the
    /// serial IPC queue. Nil in production.
    var ipcWorkEnqueuedObserver: (@Sendable () -> Void)?

    /// Current reconnect delay (doubles on each failure, capped).
    /// Widened from `private` for `DiscordRPCService+IPC.swift`.
    var reconnectDelay: TimeInterval = AppConstants.Discord.reconnectBaseDelay

    /// Active polling task (availability checks while disconnected).
    private var pollTask: Task<Void, Never>?

    /// Active reconnect task (scheduled after a connection loss).
    /// Widened from `private` for `DiscordRPCService+IPC.swift`.
    var reconnectTask: Task<Void, Never>?

    /// Event-driven queue-owned reader for unsolicited frames. Once installed,
    /// its cancel handler is the only code allowed to close ``socketFD``.
    var ipcReadSource: DispatchSourceRead?
    /// Completion fired by ``ipcReadSource``'s cancel handler after it closes
    /// the descriptor. Always installed together with the source.
    var ipcReadSourceClose: IPCDescriptorClose?
    /// Close currently executing on ``ipcQueue``. Retained after actor ownership
    /// is synchronously cleared so concurrent disconnects await the same close.
    var ipcCloseInProgress: IPCDescriptorClose?
    /// Partial-frame buffer for the current socket, shared by the idle read
    /// pump and command transactions (both run on ``ipcQueue``). Replaced on
    /// every new connection.
    var ipcReadBuffer = IPCReadBuffer()

    /// Current availability poll interval (may be widened in reduced-power mode).
    private var currentPollInterval: TimeInterval = AppConstants.Discord.availabilityPollInterval

    /// Whether the service is enabled by the user.
    /// Widened from `private` for `DiscordRPCService+IPC.swift`.
    var isEnabled = false
    /// Supersedes an older enable/disable continuation after any await.
    private var enableIntentGeneration: UInt64 = 0

    /// Process ID sent with SET_ACTIVITY (Discord requires it).
    let pid = ProcessInfo.processInfo.processIdentifier

    /// Snapshot of the most recent `updatePresence` call. Used to re-send the
    /// current activity when display settings (button labels, toggles, state format)
    /// change via `discordPresenceSettingsChanged`, so users see the effect of a
    /// label edit without waiting for the next track change.
    struct LastPresence {
        let track: String
        let artist: String
        let album: String
        let playlist: String
        /// Track length in seconds (0 if unknown).
        let duration: TimeInterval
        /// Playback position in seconds at `capturedAt`.
        let elapsed: TimeInterval
        let isPaused: Bool
        /// When the snapshot was taken; used to project `elapsed` forward on a
        /// re-send and to detect seeks in the dedup check.
        let capturedAt: Date
    }
    /// The latest track snapshot. Cleared when presence is cleared or idle is
    /// shown, except on paths that pass `preservingLastPresence: true` so a
    /// later re-enable or resume can restore the activity.
    var lastPresence: LastPresence?
    /// Newest activity waiting for the rate-limit window. Only the latest one
    /// survives a burst; ``cancelPendingPresence()`` drops it.
    var pendingActivity: [String: Any]?
    /// Delayed flush of ``pendingActivity``; non-nil while a send is scheduled.
    var presenceSendTask: Task<Void, Never>?
    /// When the last `SET_ACTIVITY` with an activity was written.
    var lastActivitySentAt: Date?
    /// Nonce of the last activity sent. A Discord ERROR reply is retried only
    /// when it matches, so a rejection of an older payload is ignored.
    var lastActivityNonce: String?
    /// Whether the one allowed retry for the current activity was spent. Reset
    /// whenever a new activity is queued.
    var presenceRetryUsed = false
    /// Minimum seconds between activity sends. Discord rate-limits
    /// `SET_ACTIVITY`, so updates inside this window are coalesced.
    var presenceMinimumInterval: TimeInterval = 4

    /// Observer token for `discordPresenceSettingsChanged`.
    private nonisolated(unsafe) var settingsObserver: NSObjectProtocol?

    /// Cached result of `readDiscordTmpDir()` to avoid sysctl on every connect.
    var cachedDiscordTmpDir: String?
    /// When `cachedDiscordTmpDir` was last populated.
    var cachedDiscordTmpDirAt: Date = .distantPast
    /// How long the TMPDIR cache is valid (Discord's TMPDIR doesn't change mid-session).
    let discordTmpDirTTL: TimeInterval = 30

    // MARK: - Init

    /// Creates the service. Does not connect until `setEnabled(true)` is called.
    ///
    /// Registers a main-queue observer for `discordPresenceSettingsChanged`
    /// that re-sends the current presence.
    ///
    /// - Parameters:
    ///   - clientID: Discord Application ID. If nil, attempts to resolve
    ///     from Info.plist (`DISCORD_CLIENT_ID`) or environment. An empty result
    ///     leaves the service unable to connect (``ConnectionFailure/notConfigured``).
    ///   - ipcSocketOpener: Opens and connects a socket for `(path, slot)`,
    ///     returning the fd or -1. Runs on ``ipcQueue``. Tests inject fakes.
    ///   - ipcSocketCloser: Closes a descriptor. Runs on ``ipcQueue``; tests use
    ///     it to count closes.
    ///   - ipcTransactionTimeoutNanoseconds: Budget for one whole write/reply
    ///     transaction, in nanoseconds.
    init(
        clientID: String? = nil,
        ipcSocketOpener: @escaping @Sendable (String, Int) -> Int32 = {
            DiscordRPCService.openIPCSocket(at: $0, slot: $1)
        },
        ipcSocketCloser: @escaping @Sendable (Int32) -> Void = { fd in
            guard fd >= 0 else { return }
            Darwin.close(fd)
        },
        ipcTransactionTimeoutNanoseconds: UInt64 = UInt64(
            AppConstants.Discord.socketTimeoutSeconds
        ) * 1_000_000_000
    ) {
        self.clientID = clientID ?? Self.resolveClientID() ?? ""
        self.ipcSocketOpener = ipcSocketOpener
        self.ipcSocketCloser = ipcSocketCloser
        self.ipcTransactionTimeoutNanoseconds = ipcTransactionTimeoutNanoseconds

        let (stateStream, stateCont) = AsyncStream<ConnectionState>.makeStream()
        self.stateChanges = stateStream
        self.stateContinuation = stateCont

        let (artStream, artCont) = AsyncStream<ArtworkResolution>.makeStream()
        self.artworkResolutions = artStream
        self.artworkContinuation = artCont

        // Re-send presence when display settings change so users see button-label
        // edits and similar tweaks immediately. Delivery is pinned to the main
        // queue so the block never fires on an arbitrary thread while `init` is
        // still completing (the closure captures `self`); the block only hops
        // into an unstructured Task, so main-queue delivery adds no real work.
        let name = Notification.Name.discordPresenceSettingsChanged
        self.settingsObserver = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshPresenceFromSettings() }
        }
    }

    /// Removes the settings observer, cancels timers, hands the open descriptor
    /// (if any) to its single owner for closing, and finishes both streams.
    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        pollTask?.cancel()
        reconnectTask?.cancel()
        presenceSendTask?.cancel()
        if let ipcReadSource {
            // Its cancellation handler is now the descriptor's sole owner. It
            // closes only after any final event handler has returned.
            ipcReadSource.cancel()
        } else if ipcCloseInProgress == nil {
            // No source was ever installed (for example, deinit during a
            // handshake), so queue-confined direct close is still required.
            let fd = socketFD
            let closer = ipcSocketCloser
            if fd >= 0 {
                ipcQueue.async { closer(fd) }
            }
        }
        stateContinuation.finish()
        artworkContinuation.finish()
    }

    // MARK: - Public API

    /// Enables or disables the service.
    ///
    /// When enabled, immediately attempts to connect to Discord.
    /// When disabled, clears the activity, disconnects, and stops polling.
    ///
    /// Each call bumps ``enableIntentGeneration``. After every await the call
    /// checks it still owns the newest intent; if a later call won, it hands
    /// off to ``reconcileLatestEnableIntent()`` instead of finishing a stale
    /// transition.
    func setEnabled(_ enabled: Bool) async {
        enableIntentGeneration &+= 1
        let intentGeneration = enableIntentGeneration
        isEnabled = enabled

        if enabled {
            await connectIfNeeded()
            guard enableIntentGeneration == intentGeneration, isEnabled else { return }
            updateAvailabilityPolling()
        } else {
            stopPolling()
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectDelay = AppConstants.Discord.reconnectBaseDelay
            // Keep the latest snapshot until this disable still owns the intent.
            // A concurrent re-enable can then restore the activity after this
            // in-flight clear finishes instead of leaving Discord blank.
            await performClearPresence(preservingLastPresence: true)
            guard enableIntentGeneration == intentGeneration, !isEnabled else {
                await reconcileLatestEnableIntent()
                return
            }
            lastPresence = nil
            await disconnect()
            guard enableIntentGeneration == intentGeneration else {
                await reconcileLatestEnableIntent()
                return
            }
        }
    }

    /// Re-applies the newest user intent after an older async transition loses
    /// ownership. In particular, reconnects if clear/disconnect lost the socket
    /// after a concurrent re-enable already observed it as connected.
    private func reconcileLatestEnableIntent() async {
        if isEnabled {
            await connectIfNeeded()
            updateAvailabilityPolling()
            await refreshPresenceFromSettings()
        } else {
            stopPolling()
        }
    }

    /// Updates the Rich Presence to show the currently playing track.
    ///
    /// Fetches album artwork from the iTunes Search API on cache miss and
    /// re-sends the presence once the artwork URL is available. Cached artwork
    /// is used immediately on subsequent calls for the same track.
    ///
    /// - Parameters:
    ///   - track: Song title (shown as "details").
    ///   - artist: Artist name (shown as "state").
    ///   - album: Album name (shown in large image tooltip).
    ///   - playlist: Current Apple Music playlist name (empty if none / unknown).
    ///   - duration: Total track duration in seconds (0 if unknown).
    ///   - elapsed: Elapsed time in seconds (0 if unknown).
    ///   - isPaused: `true` when the loaded track is paused. Discord has no
    ///     native paused flag, so when set we omit `timestamps` (stops the live
    ///     ticker) and swap `small_image` to a `pause` art asset with a
    ///     `"Paused"` tooltip. Track text stays unchanged.
    ///   - showIdleStatus: Whether hidden paused tracks use WolfWave's idle activity.
    ///   - clearWhilePaused: Whether to hide the current track while it is paused.
    func updatePresence(
        track: String,
        artist: String,
        album: String,
        playlist: String,
        duration: TimeInterval = 0,
        elapsed: TimeInterval = 0,
        isPaused: Bool = false,
        showIdleStatus: Bool = FeatureFlags.discordShowIdleStatus,
        clearWhilePaused: Bool = FeatureFlags.discordClearWhilePaused
    ) async {
        // Steady-state dedup: the now-playing poll re-emits the same track every
        // ~5s. When nothing meaningful changed, skip building and sending the
        // SET_ACTIVITY IPC frame entirely. Genuine track changes, pause flips,
        // artwork resolution (handleResolvedLinks) and settings re-sends all call
        // sendPresenceActivity directly and bypass this guard.
        var shouldSendPresence = true
        if let last = lastPresence,
           last.track == track, last.artist == artist, last.album == album,
           last.playlist == playlist, last.isPaused == isPaused {
            // Paused: elapsed is frozen, compare directly. Playing: compare the
            // incoming elapsed against the projected position so a seek still sends.
            let reference = isPaused ? last.elapsed : last.elapsed + Date().timeIntervalSince(last.capturedAt)
            if abs(reference - elapsed) <= 2 { shouldSendPresence = false }
        }

        cachePresence(
            track: track, artist: artist, album: album, playlist: playlist,
            duration: duration, elapsed: elapsed, isPaused: isPaused
        )
        guard isEnabled, state == .connected else { return }

        // Check shared cache for immediate use (artwork + track links)
        let cached = ArtworkService.shared.cachedTrackLinks(track: track, artist: artist)
        resolveLinksIfNeeded(track: track, artist: artist)

        if isPaused && clearWhilePaused {
            if shouldSendPresence {
                await sendNoTrackPresence(
                    showIdleStatus: showIdleStatus,
                    preservingLastPresence: true
                )
            }
            return
        }

        guard shouldSendPresence else { return }
        await sendPresenceActivity(
            track: track, artist: artist, album: album, playlist: playlist,
            artworkURL: cached.artworkURL,
            duration: duration, elapsed: elapsed,
            appleMusicURL: cached.trackViewURL,
            songLinkURL: cached.songLinkURL,
            isPaused: isPaused
        )
    }

    /// Starts a one-time `ArtworkService` lookup for the track's artwork and
    /// links, unless one was already attempted. When it returns anything new,
    /// ``handleResolvedLinks(track:artist:links:)`` re-sends the presence.
    func resolveLinksIfNeeded(track: String, artist: String) {
        guard !ArtworkService.shared.hasAttemptedTrackLinks(track: track, artist: artist) else {
            return
        }
        ArtworkService.shared.fetchTrackLinks(track: track, artist: artist) { [weak self] links in
            guard let self else { return }
            let hasNewData = links.artworkURL != nil
                || links.trackViewURL != nil
                || links.songLinkURL != nil
            guard hasNewData else { return }

            Task { [weak self] in
                guard let self else { return }
                await self.handleResolvedLinks(track: track, artist: artist, links: links)
            }
        }
    }

    /// Updates the availability poll interval and restarts the timer if currently polling.
    ///
    /// - Parameter interval: New poll interval in seconds.
    func updatePollInterval(_ interval: TimeInterval) {
        currentPollInterval = interval
        if pollTask != nil {
            stopPolling()
            startPolling()
        }
    }

    /// Clears the Rich Presence (e.g., when playback stops).
    func clearPresence() async {
        await performClearPresence()
    }

    /// Shows the opt-in "Idle" activity used when nothing is playing and the
    /// user chose to keep WolfWave visible on their profile instead of clearing
    /// it. No track, timestamps, or buttons, just a static idle marker.
    func showIdleStatus() async {
        await performShowIdleStatus(preservingLastPresence: false)
    }

    /// Sends the idle activity if connected.
    ///
    /// - Parameter preservingLastPresence: Keep ``lastPresence`` so a resume
    ///   can restore the track (used when a paused track is hidden).
    func performShowIdleStatus(preservingLastPresence: Bool) async {
        if !preservingLastPresence {
            lastPresence = nil
        }
        guard state == .connected else { return }
        await sendActivityFrame(DiscordPresenceBuilder.buildIdleActivity())
    }

    // MARK: - Resolution Handling

    /// Applies a finished artwork / link lookup.
    ///
    /// Ignored when the track has changed since the lookup started. Otherwise
    /// re-sends the presence (now using the cached links) and yields the
    /// artwork URL on ``artworkResolutions``.
    private func handleResolvedLinks(
        track: String,
        artist: String,
        links: TrackLinks
    ) async {
        guard isEnabled, state == .connected,
              let current = lastPresence,
              current.track == track,
              current.artist == artist else { return }
        await refreshPresenceFromSettings()
        // Notify listeners (e.g., WebSocket server) only when artwork is resolved
        if let artworkURL = links.artworkURL {
            artworkContinuation.yield(
                ArtworkResolution(url: artworkURL, track: track, artist: artist)
            )
        }
    }

    // MARK: - Client ID Resolution

    /// Resolves the Discord Application ID from Info.plist or environment.
    ///
    /// Lookup order:
    /// 1. `DISCORD_CLIENT_ID` key in Info.plist (expanded from Config.xcconfig at build time)
    /// 2. `DISCORD_CLIENT_ID` environment variable (for dev/CI overrides)
    ///
    /// - Returns: The client ID string, or nil if not configured.
    nonisolated static func resolveClientID() -> String? {
        if let plistValue = Bundle.main.object(forInfoDictionaryKey: "DISCORD_CLIENT_ID") as? String,
           !plistValue.isEmpty,
           plistValue != "$(DISCORD_CLIENT_ID)",
           plistValue != "your_discord_application_id_here" {
            return plistValue
        }

        if let env = ProcessInfo.processInfo.environment["DISCORD_CLIENT_ID"], !env.isEmpty {
            return env
        }

        return nil
    }

    // IPC connection, frame I/O, and reconnection (connectIfNeeded,
    // openIPCSocket, performHandshake, disconnect, runOnIPCQueue, writeFully,
    // readFully, sendCommandFrame, performIPCTransaction, readIPCFrame,
    // decodeFramePayload, nextBackoff, handleConnectionLost, attemptReconnect)
    // live in DiscordRPCService+IPC.swift.

    // MARK: - Polling

    /// Pure lifecycle policy shared by connection transitions and tests.
    ///
    /// Poll only while enabled, configured with a client ID, and fully
    /// disconnected (never while a connect is in flight).
    nonisolated static func shouldPollAvailability(
        isEnabled: Bool,
        clientID: String,
        state: ConnectionState
    ) -> Bool {
        isEnabled
            && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state == .disconnected
    }

    /// Whether the coarse availability timer currently exists.
    ///
    /// Test seam: state probe read only by `DiscordRPCServiceTests`.
    var isAvailabilityPolling: Bool { pollTask != nil }

    /// Synchronizes the timer with the current enabled/connection state.
    func updateAvailabilityPolling() {
        if Self.shouldPollAvailability(
            isEnabled: isEnabled,
            clientID: clientID,
            state: state
        ) {
            startPolling()
        } else {
            stopPolling()
        }
    }

    /// Starts polling for Discord availability when not connected.
    ///
    /// No-op if a poll task already exists. The interval is captured at start,
    /// so ``updatePollInterval(_:)`` restarts the task to apply a new one.
    func startPolling() {
        guard pollTask == nil else { return }

        let interval = currentPollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Availability polling tolerates coarse timing, allow 10%
                // tolerance so the wakeup coalesces with other timers.
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.1))
                guard !Task.isCancelled, let self else { return }
                await self.pollTick()
            }
        }
    }

    /// One poll iteration: tries to connect if still enabled and disconnected.
    private func pollTick() async {
        guard isEnabled, state == .disconnected else { return }
        await connectIfNeeded()
    }

    /// Stops the availability poll timer.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
