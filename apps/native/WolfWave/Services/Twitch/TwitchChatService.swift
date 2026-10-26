//
//  TwitchChatService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-01-08.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Network

// MARK: - Helix Response Models

/// `GET /helix/users` response. Used by `fetchBotIdentity` and `resolveUsername`.
nonisolated struct HelixUsersResponse: Decodable {
    struct User: Decodable {
        let id: String
        let login: String
        let displayName: String?
    }
    let data: [User]
}

/// `GET https://id.twitch.tv/oauth2/validate` response. Used by `validateToken`.
///
/// `login` and `userID` are parsed so the app can tell a streamer they are
/// signed in as the wrong account. Without them, "you're signed in as your bot
/// account, not your broadcaster account" is unsayable outside the channel
/// points path, which models it as `RedemptionStatus.botAccount`.
nonisolated struct TwitchValidateResponse: Decodable {
    let clientID: String?
    let scopes: [String]?
    let login: String?
    let userID: String?

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case scopes
        case login
        case userID = "user_id"
    }
}

/// `POST /helix/chat/messages` response. Used by `sendMessage` to confirm delivery.
nonisolated struct HelixSendMessageResponse: Decodable {
    struct SentMessage: Decodable {
        let isSent: Bool
    }
    let data: [SentMessage]
}

/// `GET /helix/streams` response. Used by `seedStreamLiveState`.
nonisolated struct HelixStreamsResponse: Decodable {
    struct Stream: Decodable {
        let id: String
        /// ISO-8601 stream start time, e.g. `2026-06-08T18:04:21Z`. Anchors the
        /// `!stats` "This stream" window when seeding mid-broadcast. Decoded from
        /// the JSON `started_at` field via the snake-case key strategy.
        let startedAt: String?
    }
    let data: [Stream]
}

/// Maps an `HTTPClient.HTTPError` to the matching `TwitchChatService.ConnectionError`.
/// Preserves the existing 401 → `authenticationFailed` mapping; everything else
/// becomes `.networkError(...)` with the underlying description.
nonisolated func mapHelixError(_ error: Error) -> TwitchChatService.ConnectionError {
    if let httpError = error as? HTTPClient.HTTPError {
        switch httpError {
        case .unexpectedStatus(401, _):
            return .authenticationFailed
        case .unexpectedStatus(let code, _):
            return .networkError("HTTP \(code)")
        case .invalidResponse:
            return .networkError("No HTTP response")
        case .decodingFailed:
            return .networkError("Unable to decode response")
        case .transport(let underlying):
            return .networkError(underlying.localizedDescription)
        }
    }
    if let connectionError = error as? TwitchChatService.ConnectionError {
        return connectionError
    }
    return .networkError(error.localizedDescription)
}

/// What a live token-validation request proves about the Polls OAuth scope.
///
/// Only ``present`` and ``missing`` are proof. ``indeterminate`` (transport
/// error, non-401 failure status, or an unparseable body) must not be treated as
/// a missing scope, or a Twitch hiccup would turn off Polls-mode vote-skip.
nonisolated enum PollScopeValidation: Equatable, Sendable {
    /// Twitch confirmed the token carries the Polls scope.
    case present
    /// Twitch answered 401, or a 2xx scope list without the Polls scope. No
    /// token at all also maps here.
    case missing
    /// The check could not reach a verdict.
    case indeterminate
}

/// Service managing Twitch chat connection and bot commands via EventSub WebSocket.
///
/// Handles:
/// - WebSocket connection to Twitch EventSub
/// - EventSub subscriptions (channel.chat.message, channel.poll.end, redemptions)
/// - Chat message routing to bot commands
/// - Chat message sending and replies
/// - Token validation and user identity resolution
///
/// Concurrency:
/// - `actor`-isolated. The actor's own mutable state lives inside its isolation
///   domain with no locks. The only locks are in the `ProviderRegistry` mirror
///   class and the shared `Atomic` boxes that exist so the sync dispatcher
///   bridge can read state without re-entering the actor.
/// - Side-effect "callbacks" (chat messages, connection state, vote-skip poll
///   results) are surfaced as `AsyncStream`s on the `nonisolated` interface.
/// - Track-info providers (`!song`, `!last`, `!stats`) are async closures;
///   AppDelegate hops to `@MainActor` inside them.
/// - Rate-limit bookkeeping lives in a nested `RateLimiter` actor so heavy
///   request flows don't serialize the entire chat-message pipeline.
///
/// Usage:
/// ```swift
/// let service = TwitchChatService()
/// try await service.connectToChannel(
///     channelName: "streamer",
///     token: oauthToken,
///     clientID: clientID
/// )
/// try await service.sendMessage("Hello, chat!")
/// ```
actor TwitchChatService {

    // MARK: - Static Constants

    /// Posted on `NotificationCenter.default` when the connected flag changes.
    nonisolated static let connectionStateChanged =
        Notification.Name.twitchConnectionStateChanged

    /// Title used for vote-skip Twitch polls. Also the match key for `channel.poll.end`.
    nonisolated static let skipPollTitle = "Skip the current song?"
    /// "Skip" choice label on a vote-skip poll.
    nonisolated static let skipPollSkipChoice = "Skip"
    /// "Keep playing" choice label on a vote-skip poll.
    nonisolated static let skipPollKeepChoice = "Keep playing"

    // MARK: - Configuration

    /// Helix root (`https://api.twitch.tv/helix`); endpoint paths are appended.
    let apiBaseURL = AppConstants.Twitch.apiBaseURL
    /// `BotCommandDispatcher` is `@MainActor` (project default). The actor
    /// holds it as `nonisolated` (it's auto-Sendable since it's MainActor) and
    /// hops to `MainActor.run` for every call into it.
    nonisolated let commandDispatcher: BotCommandDispatcher
    /// Helix wrapper for the managed "Request a Song" reward (create,
    /// reconcile, fulfill, cancel).
    let channelPointsService: TwitchChannelPointsService
    /// Disk-backed record of paid-event outcomes (fulfill / refund and Bits
    /// actions) that must be replayed until acknowledged.
    let redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox
    /// Supplies the client ID for replayed redemption work, which can run
    /// when no channel is joined and `clientID` is `nil`.
    let redemptionClientIDProvider: @Sendable () -> String?
    /// Test seam that builds the EventSub socket. `nil` means `urlSession`
    /// creates it.
    let eventSubWebSocketFactory: (@Sendable (URL) -> URLSessionWebSocketTask)?
    /// Test seam for starting an EventSub socket; production calls `resume()`.
    let eventSubWebSocketResume: @Sendable (URLSessionWebSocketTask) -> Void
    /// Test seam for reading one EventSub frame; production calls `receive()`.
    let eventSubWebSocketReceive: @Sendable (URLSessionWebSocketTask) async throws
        -> URLSessionWebSocketTask.Message
    /// Per-endpoint Helix bucket tracker. Its own actor, so a request waiting
    /// for capacity does not hold this actor.
    let rateLimiter = RateLimiter()

    /// Session for the EventSub socket and actor-owned requests. Waits for
    /// connectivity and never serves cached responses. Invalidated in `deinit`.
    let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    /// Narrow injection seam for EventSub subscription POST/DELETE tests.
    let eventSubHTTPClient: HTTPClient
    /// Helix request client used by chat sends and other actor-owned API calls.
    let helixHTTPClient: HTTPClient

    /// Backoff attempts allowed per transport reconnect cycle.
    let maxReconnectionAttempts = AppConstants.Twitch.maxReconnectionAttempts
    /// Network-recovery cycles allowed inside one cooldown window.
    let maxNetworkReconnectCycles = AppConstants.Twitch.maxNetworkReconnectCycles
    /// Retries for a chat send that failed with a retryable outcome.
    let maxMessageRetries = AppConstants.Twitch.maxMessageRetries

    // MARK: - WebSocket / Session

    /// The current EventSub socket. During a `session_reconnect` handoff this
    /// is the replacement; the old one lives in `migrationSourceWebSocketTask`.
    var webSocketTask: URLSessionWebSocketTask?
    /// EventSub session ID from the latest `session_welcome`. Subscriptions are
    /// created against it.
    var sessionID: String?
    /// Receive loop for `webSocketTask`.
    var receiveTask: Task<Void, Never>?
    /// EventSub session where channel.poll.end is known to be subscribed.
    var pollSubscriptionSessionID: String?
    /// Session currently awaiting a poll-subscription POST.
    var pollSubscriptionAttemptSessionID: String?
    /// Narrow deterministic seams for live-toggle tests.
    var pollScopeValidationOverride: (@Sendable () async -> PollScopeValidation)?
    /// Test seam replacing the `channel.poll.end` subscription POST. Receives
    /// the session ID and returns whether the subscription succeeded.
    var pollSubscriptionOverride: (@Sendable (String) async -> Bool)?

    /// During Twitch's `session_reconnect` handoff the source socket must stay
    /// open and continue delivering events until the replacement sends welcome.
    /// These fields retain that source independently from the new current socket.
    var migrationSourceWebSocketTask: URLSessionWebSocketTask?
    /// Receive loop that keeps draining `migrationSourceWebSocketTask`.
    var migrationSourceReceiveTask: Task<Void, Never>?
    /// Socket that most recently completed the welcome handshake. Unlike
    /// `sessionID`, object identity distinguishes the old welcomed session from
    /// a replacement socket that is still waiting for its own welcome.
    var welcomedWebSocketTask: URLSessionWebSocketTask?

    /// One long-lived keepalive watchdog per EventSub session. Inbound frames
    /// update ``lastKeepaliveActivity`` instead of cancelling and allocating a
    /// new sleeping task for every busy-chat message.
    var keepaliveWatchdogTask: Task<Void, Never>?
    /// Monotonic time of the last inbound frame. The watchdog sleeps until this
    /// plus `keepaliveDeadlineSeconds`.
    var lastKeepaliveActivity: ContinuousClock.Instant?
    /// Invalidates a watchdog that was cancelled just before it re-entered the actor.
    var keepaliveGeneration: UInt64 = 0
    /// Diagnostic counter that also locks the one-task-per-session contract in tests.
    var keepaliveWatchdogTaskStarts = 0

    /// Current keepalive deadline (seconds), set from `session_welcome`.
    var keepaliveDeadlineSeconds: TimeInterval = AppConstants.Twitch.keepaliveDefaultTimeoutSeconds

    /// True while a `session_reconnect` migration is in flight. The resulting
    /// `session_welcome` then only re-arms the watchdog and flips connected,
    /// skipping the `subscribeTo*` calls because subscriptions migrate with the
    /// reconnect_url session.
    var isMigratingSession = false

    /// Dedup store for inbound EventSub frames. Twitch delivers at-least-once,
    /// so `handleWebSocketMessage` drops any frame whose `metadata.message_id`
    /// was already seen. Actor-isolated, mutated only on the actor.
    var messageDeduplicator = EventSubMessageDeduplicator()
    /// Command-shaped chat IDs retain the complete replay TTL. Ordinary chat
    /// volume must not evict a delayed duplicate before it can rerun a command.
    var commandMessageDeduplicator = EventSubMessageDeduplicator(maxEntries: nil)

    // MARK: - Credentials

    // Set together by a channel join and cleared together on leave. `nil`
    // means no channel is joined. Never persisted here; the Keychain owns them.

    /// Twitch user ID of the joined channel.
    var broadcasterID: String?
    /// Twitch user ID of the signed-in account that sends chat. Equal to
    /// `broadcasterID` when the streamer signed in as themselves, which the
    /// channel-points path requires.
    var botID: String?
    /// Access token used for Helix calls and EventSub subscriptions.
    var oauthToken: String?
    /// Twitch application client ID sent as `Client-Id`.
    var clientID: String?

    /// Live `SongRequestService`, used by the channel-point and bit redemption
    /// handlers. Set by `AppDelegate` via `setSongRequestServiceReference(_:)`.
    var songRequestService: SongRequestService?

    // MARK: - Toggles

    /// Whether a successful `channel.chat.message` subscription posts the
    /// "connected" chat message. A user-initiated join turns it on; the silent
    /// launch auto-reconnect turns it off so chat isn't spammed on every launch.
    var shouldSendConnectionMessageOnSubscribe = true
    /// Whether chat commands are dispatched. Always `true` in production; only
    /// `setCommandsEnabledForTesting(_:)` turns it off.
    private(set) var commandsEnabled = true

    // MARK: - Track-Info Providers (async, nonisolated)

    /// Providers live in a nonisolated lock-protected registry so AppDelegate
    /// can set them synchronously from MainActor, and the dispatcher closures
    /// wired in `joinChannel` (which run on MainActor) can read them without
    /// awaiting this actor.
    nonisolated let providers = ProviderRegistry()

    // MARK: - UserDefaults-derived (read on demand)

    /// Whether the current song command is enabled (computed from UserDefaults on each access).
    nonisolated var currentSongCommandEnabled: Bool {
        Preferences.bool(
            AppConstants.UserDefaults.currentSongCommandEnabled,
            default: AppConstants.UserDefaults.Defaults.currentSongCommandEnabled
        )
    }

    /// Whether the last song command is enabled (computed from UserDefaults on each access).
    nonisolated var lastSongCommandEnabled: Bool {
        Preferences.bool(
            AppConstants.UserDefaults.lastSongCommandEnabled,
            default: AppConstants.UserDefaults.Defaults.lastSongCommandEnabled
        )
    }

    /// Whether the `!stats` command should respond. Both the Stats feature and
    /// the command itself must be enabled (computed from UserDefaults).
    nonisolated var statsCommandActive: Bool {
        let stats = DefaultsStore.store.bool(forKey: AppConstants.UserDefaults.statsEnabled)
        let command = DefaultsStore.store.bool(forKey: AppConstants.UserDefaults.statsCommandEnabled)
        return stats && command
    }

    // MARK: - Connection State

    /// Actor-owned connected flag. Written only through `setConnected(_:)`;
    /// every write is mirrored into `isConnectedSnapshot`.
    private var _connected = false {
        didSet { isConnectedSnapshot.set(_connected) }
    }
    /// Latch so the connection chat message goes out at most once per join.
    /// Reset on join and on disconnect.
    var hasSentConnectionMessage = false
    /// Whether the channel is live, from Helix on connect and then the
    /// `stream.online` / `stream.offline` events. Read by the "Only reply while
    /// live" gate (off by default) and anchors the `!stats` "This stream" window.
    var streamLive = false {
        didSet { streamLiveSnapshot.set(streamLive) }
    }

    /// When the current stream went live, or `nil` when offline. Anchors the
    /// `!stats` command's "This stream" window. Seeded from Helix `started_at` on
    /// connect and updated by the `stream.online` / `stream.offline` events.
    var streamLiveSince: Date? {
        didSet { streamSinceSnapshot.set(streamLiveSince) }
    }

    /// Nonisolated mirror of `_connected` so MainActor UI code (status chips,
    /// menu bar enable state) can read it without `await`.
    nonisolated let isConnectedSnapshot = Atomic(false)

    /// Nonisolated read of the connection state, mirroring the actor-isolated
    /// `isConnected`. Lets synchronous MainActor callers (menu bar, status
    /// chips, settings panes) check the connection without `await` instead of
    /// reaching through `isConnectedSnapshot.value` at every site.
    nonisolated var currentlyConnected: Bool { isConnectedSnapshot.value }

    /// Nonisolated mirror of `streamLive` so the synchronous dispatcher bridge
    /// (the "Only reply while live" gate) can read it without re-entering the actor.
    nonisolated let streamLiveSnapshot = Atomic(false)

    /// Nonisolated mirror of `streamLiveSince` so the synchronous `!stats`
    /// provider (MainActor) can read the stream's start time without `await`.
    nonisolated private let streamSinceSnapshot = Atomic<Date?>(nil)

    /// When the current stream went live, or `nil` when offline. Readable from any
    /// isolation (mirrors the actor-isolated `streamLiveSince`).
    nonisolated var currentStreamLiveSince: Date? { streamSinceSnapshot.value }

    /// Actor-isolated connection state. Turns `true` only after the session is
    /// welcomed and its chat subscription succeeds (or a migration completes).
    var isConnected: Bool { _connected }

    /// Raw write of the connected flag. Posts nothing; transitions that the UI
    /// must see go through `broadcastConnectionState(_:error:)`.
    func setConnected(_ value: Bool) {
        _connected = value
    }

    /// Broadcasts a connection-state transition to every consumer surface: the
    /// actor's `_connected` flag (and its atomic mirror), the NotificationCenter
    /// post observed by the UI, and every per-subscriber connection-state
    /// stream. The single write path for connection-state transitions.
    ///
    /// - Parameter error: Optional failure description attached to the
    ///   notification payload (transport errors only).
    func broadcastConnectionState(_ connected: Bool, error: String? = nil) {
        // State streams model transitions, not repeated teardown calls. Preserve
        // an explicit error notification even if the state was already false.
        guard _connected != connected || error != nil else { return }
        setConnected(connected)
        // Post on the main actor: this runs on the actor's background executor,
        // and SwiftUI panes observe via NotificationCenter.publisher + .onReceive,
        // which delivers synchronously on the posting thread with no main hop.
        // Mutating MainActor view state off-main is the documented executor-assert
        // SIGTRAP class, so hop here to cover every current and future observer.
        Task { @MainActor in
            NotificationCenter.default.postTwitchConnectionState(isConnected: connected, error: error)
        }
        connectionStateHub.yield(connected)
    }

    // MARK: - Disconnect / Network State

    /// True between a disconnect starting and the next connection attempt.
    /// Inbound frames, reconnect attempts, and queued chat retries bail out
    /// while it is set, so a teardown can't be raced by late work.
    var isProcessingDisconnect = false
    /// Synchronous signal observed by the receive loop after its socket is
    /// closed for credential teardown. Unlike cancelling the receive task, this
    /// lets a frame already awaiting actor admission finish paid-event intake.
    nonisolated let eventSubTeardownQuiescing = Atomic(false)
    /// Nesting count of in-flight `leaveChannel` calls. `eventSubTeardownQuiescing`
    /// is cleared only when the outermost one exits.
    var eventSubCredentialTeardownFenceDepth = 0
    /// Invalidates channel joins that resume after a leave or a newer connect attempt.
    var connectionGeneration: UInt64 = 0
    /// Changes only for an explicit public join/connect, not automatic transport
    /// reconnects. A leave suspended on its final reward pause uses this to avoid
    /// clearing a newer same-account user-initiated join.
    var channelOwnershipGeneration: UInt64 = 0

    /// Ownership captured by one EventSub receive loop. Both the logical
    /// generation and WebSocket object identity must still match after an await.
    struct EventSubReceiveContext: Sendable {
        let generation: UInt64
        let webSocketTask: URLSessionWebSocketTask
    }

    /// Whether work started by a receive loop may still act after an await.
    ///
    /// - Parameter context: The loop's captured ownership, or `nil` for work
    ///   not tied to a socket (only cancellation is checked then).
    /// - Returns: `false` once the task is cancelled, the connection attempt is
    ///   superseded or torn down, or the socket is neither the current one nor
    ///   the migration source still draining during a reconnect handoff.
    func receiveContextIsCurrent(_ context: EventSubReceiveContext?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let context else { return true }
        return connectionAttemptIsCurrent(context.generation)
            && (webSocketTask === context.webSocketTask
                || migrationSourceWebSocketTask === context.webSocketTask)
    }
    /// Watches network reachability so a drop disconnects and a return
    /// reconnects. Callbacks run on `networkMonitorQueue`.
    var networkPathMonitor: NWPathMonitor?
    /// Feeds path updates from `networkMonitorQueue` into the ordered consumer.
    var networkPathContinuation: AsyncStream<Bool>.Continuation?
    /// The single consumer that applies reachability updates in arrival order.
    var networkPathTask: Task<Void, Never>?
    /// Invalidates callbacks already queued by a canceled/replaced path monitor.
    var networkMonitorGeneration: UInt64 = 0
    /// Serial queue `NWPathMonitor` requires for its callbacks.
    let networkMonitorQueue = DispatchQueue(
        label: "com.mrdemonwolf.wolfwave.networkmonitor")
    /// Last reachability seen. While `false`, reconnects are not scheduled.
    var isNetworkReachable = true

    // MARK: - Reconnection State

    /// Backoff attempts used in the current reconnect cycle. Reset once a
    /// session is usable (chat subscribed or migration done), on leave or a
    /// terminal stop, and on an accepted network-recovery cycle.
    var reconnectionAttempts = 0
    /// The pending backoff-then-reconnect task, if one is scheduled.
    var reconnectTask: Task<Void, Never>?
    /// Times out a socket that never sends `session_welcome`.
    var sessionWelcomeTask: Task<Void, Never>?
    /// Pending send of the one-time "connected" chat message.
    var connectionMessageTask: Task<Void, Never>?

    /// Tracks total network-triggered reconnect cycles to prevent infinite loops
    /// when the network path flaps repeatedly.
    var networkReconnectCycles = 0
    /// Unix epoch seconds of the last accepted network-recovery cycle. The
    /// cycle counter resets once `networkReconnectCooldown` has passed.
    var lastNetworkReconnectTime: TimeInterval = 0

    // What an automatic reconnect rejoins with. Published by a channel join and
    // cleared on leave; `nil` channel means there is nothing to reconnect.

    /// Channel login the automatic reconnect rejoins.
    var reconnectChannelName: String?
    /// Access token for the automatic reconnect.
    var reconnectToken: String?
    /// Client ID for the automatic reconnect.
    var reconnectClientID: String?

    /// Single service seam for every live 401. The rejected access expectation
    /// is mandatory so an old request can never refresh a replacement account.
    private var reactiveTokenRefreshOperation: @Sendable (
        String,
        TwitchCredentialStore.AccessExpectation
    ) async throws -> TwitchTokenRefresher.RefreshResult = { clientID, expected in
        try await TwitchTokenRefresher.attemptReactiveRefresh(
            clientID: clientID,
            expected: expected
        )
    }

    /// Sleep used between redemption fulfill / refund retries. Injectable so
    /// tests don't wait real time.
    var redemptionResolutionSleep: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    /// Test seam: replaces the reactive 401 token refresher.
    func setReactiveTokenRefresh(
        _ operation: @escaping @Sendable (
            String,
            TwitchCredentialStore.AccessExpectation
        ) async throws -> TwitchTokenRefresher.RefreshResult
    ) {
        reactiveTokenRefreshOperation = operation
    }

    /// Runs the injectable refresher for the exact credential rejected by an
    /// earlier request.
    func reactiveTokenRefresh(
        _ clientID: String,
        expected: TwitchCredentialStore.AccessExpectation
    ) async throws -> TwitchTokenRefresher.RefreshResult {
        try await reactiveTokenRefreshOperation(clientID, expected)
    }

    /// Test seam: replaces `redemptionResolutionSleep`.
    func setRedemptionResolutionSleep(
        _ operation: @escaping @Sendable (Duration) async throws -> Void
    ) {
        redemptionResolutionSleep = operation
    }

    // MARK: - Pending Messages

    /// Chat sends waiting for a retry, oldest first.
    var pendingMessages: [PendingMessage] = []
    /// The task draining `pendingMessages`, if one is running.
    var pendingRetryTask: Task<Void, Never>?
    /// Invalidates a cancelled drain so its deferred cleanup cannot clear a newer task.
    var pendingRetryGeneration: UInt64 = 0

    /// Read-only lifecycle snapshots used by diagnostics and focused tests.
    var pendingMessageCount: Int { pendingMessages.count }
    var hasPendingMessageRetry: Bool { pendingRetryTask != nil }

    // MARK: - Command Tasks

    /// In-flight command pipelines. Each task awaits its command but does not
    /// block the serial EventSub receive loop, and is owned by one connection
    /// generation so reconnect/leave can cancel it deterministically.
    var commandTasks: [UUID: Task<Void, Never>] = [:]

    /// Number of in-flight command pipelines. Exposed for tests.
    var activeCommandTaskCount: Int { commandTasks.count }

    // MARK: - Redemption Pipeline Tasks

    /// Identity of one Bits event in the in-memory fallback: the EventSub
    /// message ID scoped to its channel.
    struct VolatileBitsFallbackKey: Hashable {
        let messageID: String
        let broadcasterID: String
    }

    /// A Bits event held in memory because the durable outbox write failed.
    struct VolatileBitsFallback {
        let item: TwitchRedemptionResolutionOutbox.BitsItem
        /// When the event was claimed; drives freshness-horizon pruning.
        let claimedAt: Date
        /// Whether the request / boost has already been applied. A completed
        /// entry stays as a duplicate guard until it ages out.
        var completed: Bool
    }

    /// Process-owned fallback used only when the atomic outbox write fails.
    /// Completed entries remain non-evicting for the full EventSub freshness
    /// horizon; incomplete entries remain until they can run or the process exits.
    var volatileBitsFallbacks:
        [VolatileBitsFallbackKey: VolatileBitsFallback] = [:]

    /// In-flight channel-point pipelines, keyed by their durable intake item so
    /// duplicate EventSub delivery cannot process the same payment twice.
    /// Like bits work, these pipelines survive socket reconnects: only their
    /// chat reply is generation-bound. Deinit still cancels them.
    var redemptionTasks: [UUID: Task<Void, Never>] = [:]
    /// Bits represent an irreversible viewer payment. Their request pipeline
    /// therefore outlives EventSub socket generations; only the eventual chat
    /// reply is gated to the originating session.
    var paidRedemptionTasks: [UUID: Task<Void, Never>] = [:]
    /// Durable Bits items whose boost / request already ran in this process
    /// but whose outbox acknowledgement has not been written yet. Replay
    /// only acknowledges these; it never applies the paid action again. A
    /// relaunch starts empty, so an item the process never confirmed is
    /// still applied once from disk.
    var appliedUnacknowledgedBitsItemIDs: Set<UUID> = []
    /// Number of in-flight Bits pipelines. Exposed for tests.
    var activePaidRedemptionTaskCount: Int { paidRedemptionTasks.count }
    /// Fulfillment/refund HTTP work outlives its originating EventSub session so
    /// reconnect/leave can never strand already-spent viewer points.
    var redemptionResolutionTasks: [UUID: Task<Void, Never>] = [:]
    /// Ownership token preventing a canceled worker's deferred cleanup from
    /// deleting a newer replay task for the same persisted item.
    var redemptionResolutionWorkerIDs: [UUID: UUID] = [:]

    // MARK: - AsyncStream Outputs

    /// Stream of chat messages received via EventSub `channel.chat.message`.
    nonisolated let chatMessages: AsyncStream<ChatMessage>
    /// Stream of finished vote-skip poll tallies.
    nonisolated let skipPollResults: AsyncStream<SkipPollResult>

    /// Write end of `chatMessages`. Finished in `deinit`.
    let chatMessagesContinuation: AsyncStream<ChatMessage>.Continuation
    /// Write end of `skipPollResults`. Finished in `deinit`.
    let skipPollResultsContinuation: AsyncStream<SkipPollResult>.Continuation

    /// Fan-out registry backing `connectionStateChanges()`. One continuation
    /// per live subscriber; `broadcastConnectionState` yields to all of them.
    nonisolated private let connectionStateHub = ConnectionStateHub()

    /// Returns a fresh stream of connection state transitions (`true` = connected).
    ///
    /// Each call registers its own subscriber, so multiple consumers all
    /// receive every transition, and cancelling one consumer (e.g. a settings
    /// window closing its view model) never finishes anyone else's stream.
    nonisolated func connectionStateChanges() -> AsyncStream<Bool> {
        connectionStateHub.subscribe()
    }

    // MARK: - Init / Deinit

    /// Marked `@MainActor` so `BotCommandDispatcher()` (a MainActor type under
    /// project default isolation) can be constructed at init time. AppDelegate
    /// runs on MainActor; tests call from MainActor (Swift Testing) or wrap.
    @MainActor init(
        eventSubHTTPClient: HTTPClient = .shared,
        helixHTTPClient: HTTPClient = .shared,
        channelPointsService: TwitchChannelPointsService = TwitchChannelPointsService(),
        redemptionResolutionOutbox: TwitchRedemptionResolutionOutbox = .shared,
        redemptionClientIDProvider: @escaping @Sendable () -> String? = {
            TwitchChatService.resolveClientID()
        },
        eventSubWebSocketFactory: (@Sendable (URL) -> URLSessionWebSocketTask)? = nil,
        eventSubWebSocketResume: @escaping @Sendable (URLSessionWebSocketTask) -> Void = {
            $0.resume()
        },
        eventSubWebSocketReceive: @escaping @Sendable (URLSessionWebSocketTask) async throws
            -> URLSessionWebSocketTask.Message = { try await $0.receive() }
    ) {
        let chat = AsyncStream.makeStream(
            of: ChatMessage.self,
            bufferingPolicy: .bufferingNewest(AppConstants.Twitch.chatMessageStreamBuffer))
        let skip = AsyncStream.makeStream(
            of: SkipPollResult.self,
            bufferingPolicy: .bufferingNewest(AppConstants.Twitch.controlStreamBuffer))

        self.chatMessages = chat.stream
        self.chatMessagesContinuation = chat.continuation
        self.skipPollResults = skip.stream
        self.skipPollResultsContinuation = skip.continuation
        self.commandDispatcher = BotCommandDispatcher()
        self.eventSubHTTPClient = eventSubHTTPClient
        self.helixHTTPClient = helixHTTPClient
        self.channelPointsService = channelPointsService
        self.redemptionResolutionOutbox = redemptionResolutionOutbox
        self.redemptionClientIDProvider = redemptionClientIDProvider
        self.eventSubWebSocketFactory = eventSubWebSocketFactory
        self.eventSubWebSocketResume = eventSubWebSocketResume
        self.eventSubWebSocketReceive = eventSubWebSocketReceive
    }

    /// Cancels every owned task and socket, finishes the output streams, and
    /// drops this service from the redemption teardown gate.
    deinit {
        // Synchronous cleanup only. Actor isolation forbids awaits in deinit.
        sessionWelcomeTask?.cancel()
        reconnectTask?.cancel()
        receiveTask?.cancel()
        migrationSourceReceiveTask?.cancel()
        keepaliveWatchdogTask?.cancel()
        connectionMessageTask?.cancel()
        pendingRetryTask?.cancel()
        commandTasks.values.forEach { $0.cancel() }
        redemptionTasks.values.forEach { $0.cancel() }
        paidRedemptionTasks.values.forEach { $0.cancel() }
        redemptionResolutionTasks.values.forEach { $0.cancel() }
        networkPathMonitor?.cancel()
        networkPathContinuation?.finish()
        networkPathTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        migrationSourceWebSocketTask?.cancel(with: .goingAway, reason: nil)
        chatMessagesContinuation.finish()
        connectionStateHub.finish()
        skipPollResultsContinuation.finish()
        // A URLSession that is never invalidated retains its internal state
        // until the process exits. Throwaway instances (resolveBotIdentityStatic)
        // would otherwise leak one session each per OAuth/re-auth.
        urlSession.invalidateAndCancel()
        TwitchRedemptionTeardownGate.removeService(
            serviceID: ObjectIdentifier(self))
    }

    /// Test seam: toggles whether bot commands are dispatched. No production
    /// caller; the app always dispatches commands.
    func setCommandsEnabledForTesting(_ enabled: Bool) {
        self.commandsEnabled = enabled
    }

    // Helix rate limiter (nested actor) lives in TwitchChatService+RateLimiter.swift

    // Network monitoring + reconnection lifecycle lives in TwitchChatService+Connection.swift

    // Message sending + retry queue lives in TwitchChatService+Sending.swift

    // EventSub message parsing (handleEventSubMessage) lives in TwitchChatService+EventSub.swift

    // WebSocket connection management lives in TwitchChatService+Connection.swift

    // Keepalive watchdog + WebSocket receive loop live in TwitchChatService+Connection.swift

    // EventSub message routing (handleWebSocketMessage, handleSessionReconnect,
    // handleRevocation, signalReauthNeededAndStop, handleSessionWelcome,
    // handleNotification, handlePollEndEvent) lives in TwitchChatService+EventSub.swift

    // Vote-skip polls, stream-state handling, and EventSub subscriptions
    // (createSkipPoll, subscribeToPollEvents, handleStreamStateNotification,
    // subscribeToChannelChatMessage, subscribeToStreamEvents, seedStreamLiveState,
    // postEventSubSubscription) live in TwitchChatService+EventSub.swift

    // Redemption EventSub subscriptions (subscribeToRedemptionsIfEnabled,
    // refreshRedemptionSubscriptions, ensureSongRequestRewardAndSubscribe,
    // pauseManagedRewardIfPossible, subscribeToChannelPointsRedemption,
    // subscribeToBitsUse) live in TwitchChatService+RedemptionSubscriptions.swift

    // Redemption event handlers (handleChannelPointsRedemption,
    // runChannelPointsRedemption, clearRedemptionTask, handleBitsUse,
    // startBitsEvent, applyPersistedBitsEvent, replayPendingBitsEvents) live in
    // TwitchChatService+RedemptionHandlers.swift

    // Redemption helpers (redemptionOutcome, bitsOutcomeMessage,
    // currentChannelPointCredentials, channelPointsCostSetting, bitsMinimumSetting,
    // setRedemptionStatus, cleanBitsMessage, stripLeadingCheermotes) live in
    // TwitchChatService+Redemptions.swift

    // Channel/username resolution (validateChannelExists, resolveUsername) lives in
    // TwitchChatService+Auth.swift

}
