//
//  ListeningHistoryService.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-05-22.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Foundation
import Observation

/// Orchestrates the opt-in Listening History & Stats feature.
///
/// Owns the append-only `PlayLogStore`, keeps an in-memory copy of the
/// retained plays (capped at `AppConstants.History.maxRetainedRecords`; older
/// plays fold into a `LifetimeTally` when retention is Forever), applies the
/// scrobble threshold, and exposes a derived `StatsSnapshot` for the UI and
/// the `!stats` Twitch command.
///
/// Durability rules this type keeps:
/// - A user clear writes a tombstone (`HistoryClearMarkerStore`) before
///   touching either store, and nothing is appended until both stores are
///   empty and the tombstone is gone, so a crash mid-clear finishes the clear
///   on next launch instead of resurrecting plays.
/// - Every record gets a monotonically increasing `sequence`. The tally keeps
///   the highest folded sequence, so a crash between saving the tally and
///   compacting the log never folds the same play twice.
/// - The tally is saved before the log is compacted, never the other way.
///
/// Recording only happens while `isEnabled` is `true`. Stats are derived in
/// memory, so they cost zero disk writes.
@MainActor
@Observable
final class ListeningHistoryService {

    // MARK: - Observable State

    /// Whether plays are currently being recorded to disk.
    private(set) var isEnabled: Bool

    /// Retained plays, oldest first, at most `maxRetainedRecords`. Loaded from
    /// disk on `start()` and appended to live as tracks change.
    var records: [PlayRecord] = []

    /// Derived statistics, recomputed whenever `records` changes.
    private(set) var snapshot: StatsSnapshot = .empty

    /// Whether the initial disk load has completed.
    var isLoaded = false

    // MARK: - Private

    /// Append-only NDJSON play log.
    let store: PlayLogStore
    /// Sidecar holding counts for plays trimmed out of `records`.
    let tallyStore: LifetimeTallyStore
    /// Durable "clear in progress" tombstone shared by both stores.
    let clearMarkerStore: HistoryClearMarkerStore

    /// While true, the durable clear tombstone remains and no new record may be
    /// appended: recovery would intentionally delete anything written behind it.
    var clearIsPending: Bool

    /// Lifetime tally of trimmed plays. Merged into every snapshot so
    /// totals/top-N stay accurate after the rolling window evicts records.
    var lifetime: LifetimeTally = .empty

    /// Set to `true` when `records` has been mutated past the cap but the
    /// NDJSON file has not yet been compacted. Drives `shutdown()` rewrite.
    var needsCompaction = false

    /// The in-memory lifetime high-water mark has not yet been saved. A tally
    /// save must succeed before compaction may remove its source NDJSON lines.
    var needsTallyPersistence = false

    /// Sequence assigned to the next live record. Disk load establishes this
    /// before buffered plays are appended, avoiding collisions across launches.
    var nextSequence: UInt64 = 1

    /// `true` while `loadFromDisk()` is awaiting its background read. Plays that
    /// arrive in this window are buffered (see `deferredDuringLoad`) instead of
    /// written, because the load overwrites `records` and a concurrent
    /// `replaceAll` could clobber the disk append.
    var isLoading = false

    /// Plays recorded while a disk load was in flight. Flushed in order once
    /// `loadFromDisk()` finishes so a track played mid-load isn't dropped.
    var deferredDuringLoad: [PlayRecord] = []

    /// The in-flight load, if any. Set synchronously in `scheduleLoad()` before
    /// the task is spawned so a rapid disable→enable toggle coalesces onto the
    /// single running load instead of starting a second one that would interleave
    /// the shared stores and re-fold overflow.
    var loadTask: Task<Void, Never>?
    /// Daily `prune()` loop, started with the first load and cancelled in
    /// `shutdown()`. Keeps a finite retention window honest in a long session.
    private var retentionTask: Task<Void, Never>?
    /// Invalidates disk-load results captured before a user clear. The detached
    /// reader is side-effect free; only a matching generation may publish.
    var historyGeneration = 0

    /// Deterministic test seam invoked by the detached loader immediately after
    /// its disk read. Production leaves it nil.
    let loadReadBarrier: (@Sendable () -> Void)?

    // MARK: - Init

    /// Creates the service.
    ///
    /// - Parameters:
    ///   - store: Backing play-log store. Defaults to the Application Support log.
    ///   - tallyStore: Lifetime tally store. Defaults to the Application Support sidecar.
    ///   - clearMarkerStore: Durable cross-store clear marker. Tests may inject
    ///     failure behavior; production derives it from the play-log directory.
    ///   - enabled: Initial enabled state (typically the persisted UserDefaults value).
    ///   - loadReadBarrier: Test-only hook after the detached disk read.
    init(
        store: PlayLogStore = PlayLogStore(),
        tallyStore: LifetimeTallyStore = LifetimeTallyStore(),
        clearMarkerStore: HistoryClearMarkerStore? = nil,
        enabled: Bool,
        loadReadBarrier: (@Sendable () -> Void)? = nil
    ) {
        let markerStore = clearMarkerStore ?? HistoryClearMarkerStore(
            directory: store.fileURL.deletingLastPathComponent())
        self.store = store
        self.tallyStore = tallyStore
        self.clearMarkerStore = markerStore
        self.clearIsPending = markerStore.isPending
        self.isEnabled = enabled
        self.loadReadBarrier = loadReadBarrier
    }

    // MARK: - Lifecycle

    /// Loads existing history from disk (off the main thread) if the feature is
    /// enabled. Safe to call once at launch.
    func start() {
        guard isEnabled else { return }
        scheduleLoad()
    }

    /// Enables recording and loads any existing history.
    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        scheduleLoad()
        Log.info("ListeningHistoryService: Listening History enabled", category: .history)
    }

    /// Spawns `loadFromDisk()` unless a load is already in flight, so overlapping
    /// callers (a rapid disable→enable toggle, or `start()` racing `enable()`)
    /// share one load. Two concurrent loads could interleave the shared play-log
    /// and tally stores and re-fold overflow or drop a deferred play.
    ///
    /// Also starts the daily retention loop if it isn't running.
    private func scheduleLoad() {
        guard loadTask == nil else { return }
        if retentionTask == nil {
            retentionTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(86_400))
                    } catch { return }
                    guard let self else { return }
                    self.prune()
                }
            }
        }
        // Claim load ownership before spawning the task. A track callback can
        // run immediately after start()/enable() returns and must be buffered.
        isLoading = true
        let generation = historyGeneration
        loadTask = Task { [weak self] in
            await self?.loadFromDisk(generation: generation)
            self?.loadTask = nil
        }
    }

    /// Stops recording. Existing history on disk is left intact, and the
    /// in-memory records and snapshot stay visible.
    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        Log.info("ListeningHistoryService: Listening History disabled", category: .history)
    }

    /// Flushes buffered writes. Call before the app terminates.
    ///
    /// If the in-memory window has overflowed during this session, the play
    /// log is compacted to the live records here so the next launch starts
    /// from a normalized file. The lifetime tally is also persisted.
    ///
    /// Both writes run **synchronously** so they're guaranteed to complete
    /// before `applicationWillTerminate` returns and the process exits, a
    /// detached `Task` would be racing termination.
    func shutdown() {
        retentionTask?.cancel()
        retentionTask = nil
        guard completePendingClear() else {
            store.flush()
            return
        }
        if isLoading {
            // The loader owns qualified plays only in `deferredDuringLoad`.
            // Invalidate its eventual result, reconstruct the disk watermark,
            // append those plays synchronously via flush, and leave the full
            // NDJSON untouched for next-launch normalization/compaction.
            historyGeneration &+= 1
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
            establishNextSequenceFromDisk()
            let buffered = deferredDuringLoad
            deferredDuringLoad.removeAll()
            for record in buffered {
                appendRecord(record)
            }
            store.flush()
            return
        }

        let preserveLifetime = usesLifetimeTally
        var tallyIsDurable = true
        if preserveLifetime {
            if needsCompaction || needsTallyPersistence {
                tallyIsDurable = tallyStore.save(lifetime)
            }
        } else {
            lifetime = .empty
            tallyIsDurable = tallyStore.clear()
        }
        if tallyIsDurable {
            needsTallyPersistence = false
        } else {
            needsTallyPersistence = true
        }
        if needsCompaction, tallyIsDurable {
            needsCompaction = !store.replaceAll(with: records)
        }
        store.flush()
    }

    // MARK: - Recording

    /// Records a finished play if the feature is enabled and the track crossed
    /// the scrobble threshold.
    ///
    /// Non-finite or negative durations are clamped before the threshold check.
    /// A blank title is ignored. The play is dropped (and logged) while an
    /// earlier clear can't be completed, and buffered while a disk load runs.
    ///
    /// - Parameters:
    ///   - track: Track title.
    ///   - artist: Artist name.
    ///   - album: Album title.
    ///   - duration: Track length in seconds.
    ///   - playedSeconds: How long the track actually played in seconds.
    func recordTrackChange(
        track: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        playedSeconds: TimeInterval
    ) {
        guard isEnabled else { return }
        let trimmedTrack = track.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrack.isEmpty else { return }
        let safeDuration = DurationSanitizer.clampFiniteSeconds(duration)
        let safePlayedSeconds = DurationSanitizer.clampFiniteSeconds(playedSeconds)
        guard Self.qualifiesAsPlay(
            duration: safeDuration,
            playedSeconds: safePlayedSeconds
        ) else { return }
        guard completePendingClear() else {
            Log.warn(
                "ListeningHistoryService: Play not recorded while history clear is pending",
                category: .history)
            return
        }

        let record = PlayRecord(
            track: trimmedTrack,
            artist: artist,
            album: album,
            duration: safeDuration,
            playedSeconds: safePlayedSeconds
        )

        // A disk load is awaiting its background read. Buffer the play; it would
        // otherwise be overwritten when loadFromDisk assigns `records`, and a
        // concurrent replaceAll could drop the disk append too. Flushed in order
        // by loadFromDisk once the load completes.
        guard !isLoading else {
            deferredDuringLoad.append(record)
            return
        }

        appendRecord(record)
    }

    /// Appends one already-validated play to disk + the in-memory window and
    /// enforces the rolling-window cap. The hot path stays append-only; NDJSON
    /// compaction is deferred to `shutdown()`.
    func appendRecord(_ pendingRecord: PlayRecord) {
        let record = recordWithSequence(pendingRecord)
        store.append(record)
        records.append(record)
        prune()
        let preserveLifetime = usesLifetimeTally
        if !preserveLifetime, !lifetime.isEmpty {
            lifetime = .empty
            needsTallyPersistence = !tallyStore.clear()
        }

        let cap = AppConstants.History.maxRetainedRecords
        if records.count > cap {
            let overflow = records.count - cap
            let evicted = Array(records.prefix(overflow))
            records.removeFirst(overflow)
            if preserveLifetime {
                lifetime.fold(evicted)
                needsTallyPersistence = true
                // Keep the full sidecar rewrite off the recording hot path.
                // Until shutdown compacts the log, NDJSON still contains these
                // plays so an unclean-exit reload can recover the tally.
            }
            needsCompaction = true
        }

        rebuildSnapshot()
        Log.debug(
            "ListeningHistoryService: Recorded play: \(record.track) (\(Int(record.playedSeconds))s)",
            category: .history
        )
    }

    /// Counts plays a finite retention window would remove, without mutating it.
    ///
    /// Drives the confirmation before shortening retention.
    ///
    /// - Parameters:
    ///   - retentionDays: Candidate window in days; `0` or less (Forever) returns 0.
    ///   - now: Reference time for the cutoff.
    /// - Returns: In-memory plays older than the cutoff. The lifetime tally is
    ///   also discarded under finite retention but is not counted here.
    func expiredRecordCount(retentionDays: Int, now: Date = Date()) -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return records.lazy.filter { $0.timestamp < cutoff }.count
    }

    /// Applies a new retention window immediately after user confirmation.
    ///
    /// Writes `historyRetentionDays` to `DefaultsStore`, then prunes. Moving to
    /// a finite window also deletes the lifetime tally (see ``prune(now:)``).
    func setRetentionDays(_ days: Int) {
        DefaultsStore.store.set(days, forKey: AppConstants.UserDefaults.historyRetentionDays)
        prune()
    }

    /// Removes expired plays without adding them to lifetime statistics.
    ///
    /// No-op until the first load finishes, while a load is running, while a
    /// clear is pending, or under Forever retention. Under finite retention
    /// it also deletes the lifetime tally, which has no dates to filter by.
    /// The log is rewritten only after the tally deletion is durable.
    func prune(now: Date = Date()) {
        guard isLoaded, !isLoading, !clearIsPending, !clearMarkerStore.isPending else { return }
        let days = DefaultsStore.store.integer(forKey: AppConstants.UserDefaults.historyRetentionDays)
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let hadExpiredRecords = records.contains { $0.timestamp < cutoff }
        guard hadExpiredRecords || !lifetime.isEmpty || needsTallyPersistence || needsCompaction else { return }
        if !lifetime.isEmpty || needsTallyPersistence {
            lifetime = .empty
            needsTallyPersistence = !tallyStore.clear()
        }
        if hadExpiredRecords {
            records.removeAll { $0.timestamp < cutoff }
            needsCompaction = true
        }
        // Preserve source lines until the tally deletion is durable, matching
        // load/shutdown ordering so a later Forever window cannot resurrect it.
        if needsCompaction, !needsTallyPersistence {
            needsCompaction = !store.replaceAll(with: records)
        }
        rebuildSnapshot()
    }

    /// Deletes all recorded history, on disk and in memory.
    ///
    /// - Returns: `true` only when the clear marker, play log, and lifetime
    ///   tally have all reached their durable final state.
    @discardableResult
    func clearHistory() -> Bool {
        // The marker must exist before either data store is mutated. If it
        // cannot be persisted, leave both disk and UI state untouched.
        guard clearMarkerStore.begin() else {
            Log.error(
                "ListeningHistoryService: Could not persist history clear intent",
                category: .history)
            return false
        }

        clearIsPending = true
        historyGeneration &+= 1
        // Buffered plays accumulated before the clear belong to old history.
        deferredDuringLoad.removeAll()
        records = []
        lifetime = .empty
        needsCompaction = false
        needsTallyPersistence = false
        nextSequence = 1
        isLoaded = true
        rebuildSnapshot()

        let completed = completePendingClear()
        if completed {
            Log.info(
                "ListeningHistoryService: History cleared by user",
                category: .history)
        } else {
            Log.error(
                "ListeningHistoryService: History clear pending durable retry",
                category: .history)
        }
        return completed
    }

    /// Replays a persisted clear intent. No caller may append while this returns
    /// false, because a later recovery intentionally empties both data stores.
    @discardableResult
    func completePendingClear() -> Bool {
        guard clearIsPending else { return true }
        clearIsPending = true
        let logCleared = store.clear()
        let tallyCleared = tallyStore.clear()
        guard logCleared, tallyCleared else { return false }
        guard clearMarkerStore.complete() else { return false }
        clearIsPending = false
        return true
    }

    // MARK: - Derived Data

    /// Builds the wrap for the calendar month containing `month`.
    ///
    /// Uses in-memory records only, so a month whose plays were folded into
    /// the lifetime tally reads as empty.
    func monthlyWrap(for month: Date = Date()) -> MonthlyWrapData {
        MonthlyWrap.data(from: records, month: month)
    }

    /// First day of the earliest month containing a recorded play.
    /// `nil` when no plays have been recorded yet.
    var earliestRecordedMonth: Date? {
        guard let earliest = records.map(\.timestamp).min() else { return nil }
        return Calendar.current.dateInterval(of: .month, for: earliest)?.start
    }

    /// A chat-ready one-liner for the `!stats` command.
    ///
    /// Reports the selected `parts` over the selected `window`, falling back to a
    /// friendly message when nothing played in that window. The streamer
    /// configures `window` and `parts` in **Settings → History & Stats**.
    ///
    /// - Parameters:
    ///   - window: The time slice to report over. Defaults to ``StatsWindow/today``.
    ///   - parts: The facts to include, in any order (rendered in canonical order).
    ///     Defaults to ``StatsPart/defaults``.
    ///   - sessionStart: When the current stream went live. Used by
    ///     ``StatsWindow/session``; when `nil` that window falls back to today.
    ///   - now: Reference "now" for window bounds. Injectable for tests.
    ///   - calendar: Calendar for day bucketing. Injectable for tests.
    /// - Returns: The chat line, prefixed with the 🐺 mark.
    func statsChatLine(
        window: StatsWindow = .default,
        parts: [StatsPart] = StatsPart.defaults,
        sessionStart: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        // "This stream" needs a live anchor; without one, behave like "today".
        let effectiveWindow: StatsWindow = (window == .session && sessionStart == nil) ? .today : window
        let label = effectiveWindow.chatLabel

        let since: Date?
        switch effectiveWindow {
        case .today:
            since = calendar.startOfDay(for: now)
        case .session:
            since = sessionStart
        case .week:
            let startOfToday = calendar.startOfDay(for: now)
            since = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        case .allTime:
            since = nil
        }

        let summary = StatsAggregator.windowSummary(
            from: records, since: since,
            lifetime: usesLifetimeTally ? lifetime : .empty)
        return StatsChatLine.render(label: label, summary: summary, parts: parts)
    }

    // MARK: - Scrobble Rule

    /// Whether a play is long enough to record.
    ///
    /// A play qualifies once it reaches at least half the track's length, or
    /// `scrobbleAbsoluteSeconds` (4 minutes) regardless of length.
    ///
    /// - Parameters:
    ///   - duration: Track length in seconds (0 when unknown).
    ///   - playedSeconds: How long the track played in seconds.
    /// - Returns: `true` if the play should be recorded.
    static func qualifiesAsPlay(duration: TimeInterval, playedSeconds: TimeInterval) -> Bool {
        guard playedSeconds > 0 else { return false }
        if playedSeconds >= AppConstants.History.scrobbleAbsoluteSeconds { return true }
        guard duration > 0 else { return false }
        return playedSeconds >= duration * AppConstants.History.scrobbleFraction
    }

    // MARK: - Private Helpers

    /// Assigns a sequence at the last responsible moment, after initial disk
    /// state is known. Existing sequenced records are preserved.
    private func recordWithSequence(_ record: PlayRecord) -> PlayRecord {
        if let sequence = record.sequence {
            if sequence >= nextSequence, sequence < UInt64.max {
                nextSequence = sequence + 1
            }
            return record
        }
        let sequenced = record.assigningSequence(nextSequence)
        if nextSequence < UInt64.max {
            nextSequence += 1
        }
        return sequenced
    }

    /// Reconstructs the next sequence without rewriting legacy disk records.
    /// The virtual repair follows the same file-order-only rule as disk load so
    /// deferred shutdown appends remain above the sequence migration will assign.
    private func establishNextSequenceFromDisk() {
        var previousSequence: UInt64 = 0
        for record in store.loadAll() {
            if let sequence = record.sequence, sequence > previousSequence {
                previousSequence = sequence
            } else if previousSequence < UInt64.max {
                previousSequence += 1
            }
        }
        let highWater = Swift.max(
            previousSequence,
            tallyStore.load().lastFoldedSequence ?? 0)
        nextSequence = highWater < UInt64.max ? highWater + 1 : UInt64.max
    }

    /// Recomputes the snapshot, excluding the undated lifetime sidecar whenever
    /// finite retention is active.
    func rebuildSnapshot() {
        snapshot = StatsAggregator.snapshot(
            from: records,
            lifetime: usesLifetimeTally ? lifetime : .empty)
    }

    /// Finite retention intentionally reports only retained records. The
    /// lifetime sidecar has no per-play dates, so merging it would resurrect
    /// plays outside the user's chosen retention window.
    private var usesLifetimeTally: Bool {
        DefaultsStore.store.integer(
            forKey: AppConstants.UserDefaults.historyRetentionDays) <= 0
    }
}
