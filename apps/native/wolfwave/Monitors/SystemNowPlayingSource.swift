import Foundation
import AppKit

// MARK: - SystemNowPlayingSource

/// A playback source that uses the private MediaRemote framework to capture
/// now-playing info from any app (Spotify, Chrome, web players, etc.).
class SystemNowPlayingSource: PlaybackSource {

    // MARK: - Constants

    private enum Constants {
        static let frameworkPath = AppConstants.SystemNowPlaying.frameworkPath
        static let nowPlayingChangedNotification = AppConstants.SystemNowPlaying.nowPlayingInfoDidChangeNotification
        static let queueLabel = AppConstants.DispatchQueues.systemNowPlaying
        static let checkInterval: TimeInterval = 5.0
        static let notificationDedupWindow: TimeInterval = 0.75
        static let idleGraceWindow: TimeInterval = 2.0

        static let keyTitle = "kMRMediaRemoteNowPlayingInfoTitle"
        static let keyArtist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let keyAlbum = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let keyDuration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let keyElapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let keyPlaybackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    }

    // MARK: - Properties

    weak var delegate: PlaybackSourceDelegate?

    private var currentCheckInterval: TimeInterval = Constants.checkInterval
    private var timer: DispatchSourceTimer?
    private var lastTrackSeenAt: Date = .distantPast
    private var lastNotificationAt: Date = .distantPast
    private var lastLoggedTrack: String?
    private var isTracking = false

    private let backgroundQueue = DispatchQueue(label: Constants.queueLabel, qos: .utility)

    // MARK: - Framework Loading

    private typealias MRMediaRemoteGetNowPlayingInfoFunction =
        @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction =
        @convention(c) (DispatchQueue) -> Void

    private var getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFunction?
    private var registerForNotifications: MRMediaRemoteRegisterForNowPlayingNotificationsFunction?
    private var frameworkLoaded = false

    // MARK: - Lifecycle

    init() {
        guard let handle = dlopen(Constants.frameworkPath, RTLD_LAZY) else {
            Log.warn("SystemNowPlayingSource: MediaRemote framework unavailable", category: "Music")
            return
        }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfo = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingInfoFunction.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            registerForNotifications = unsafeBitCast(sym, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
        }
        frameworkLoaded = getNowPlayingInfo != nil
        if !frameworkLoaded {
            Log.warn("SystemNowPlayingSource: Failed to resolve MediaRemote symbols", category: "Music")
        }
    }

    deinit { stopTracking() }

    // MARK: - Public Methods

    /// Begins tracking system-wide now-playing state via MediaRemote.
    func startTracking() {
        guard !isTracking else { return }
        guard frameworkLoaded else {
            notifyDelegate(status: "System Now Playing unavailable")
            return
        }
        isTracking = true
        registerForNotifications?(backgroundQueue)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingInfoChanged),
            name: NSNotification.Name(Constants.nowPlayingChangedNotification),
            object: nil
        )
        fetchNowPlayingInfo()
        setupFallbackTimer()
    }

    /// Stops tracking and tears down the notification observer and timer.
    func stopTracking() {
        guard isTracking else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name(Constants.nowPlayingChangedNotification),
            object: nil
        )
        timer?.cancel()
        timer = nil
        isTracking = false
    }

    /// Updates the fallback polling interval while tracking is active.
    func updateCheckInterval(_ interval: TimeInterval) {
        guard isTracking else { return }
        currentCheckInterval = max(interval, 1.0)
        timer?.cancel()
        timer = nil
        setupFallbackTimer()
    }

    // MARK: - Private Helpers

    @objc private func nowPlayingInfoChanged(_ notification: Notification) {
        let now = Date()
        guard now.timeIntervalSince(lastNotificationAt) >= Constants.notificationDedupWindow else { return }
        lastNotificationAt = now
        Log.debug("SystemNowPlayingSource: Now Playing notification received", category: "Music")
        fetchNowPlayingInfo()
    }

    private func fetchNowPlayingInfo() {
        getNowPlayingInfo?(backgroundQueue) { [weak self] info in
            guard let self = self else { return }
            self.processNowPlayingInfo(info)
        }
    }

    private func processNowPlayingInfo(_ info: [String: Any]) {
        let playbackRate = (info[Constants.keyPlaybackRate] as? Double) ?? 0
        let title = (info[Constants.keyTitle] as? String) ?? ""

        guard playbackRate != 0, !title.isEmpty else {
            handleNotPlayingState()
            return
        }

        let artist = (info[Constants.keyArtist] as? String) ?? ""
        let album = (info[Constants.keyAlbum] as? String) ?? ""
        let duration = (info[Constants.keyDuration] as? Double) ?? 0
        let elapsed = (info[Constants.keyElapsedTime] as? Double) ?? 0

        lastTrackSeenAt = Date()
        notifyDelegate(track: title, artist: artist, album: album, duration: duration, elapsed: elapsed)
        logTrackIfNew(title, trackName: title, artist: artist, album: album)
    }

    private func handleNotPlayingState() {
        let idleDuration = Date().timeIntervalSince(lastTrackSeenAt)
        if idleDuration < Constants.idleGraceWindow {
            scheduleCheck(after: 0.5, reason: "idle-grace-recheck")
            return
        }
        notifyDelegate(status: "No track playing")
    }

    private func notifyDelegate(status: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.playbackSource(self, didUpdateStatus: status)
        }
    }

    private func notifyDelegate(track: String, artist: String, album: String, duration: TimeInterval, elapsed: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.playbackSource(self, didUpdateTrack: track, artist: artist, album: album, duration: duration, elapsed: elapsed)
        }
    }

    private func logTrackIfNew(_ key: String, trackName: String, artist: String, album: String) {
        let dedupKey = trackName + " | " + artist + " | " + album
        guard lastLoggedTrack != dedupKey else { return }
        Log.debug("SystemNowPlayingSource: Now Playing → \(trackName) — \(artist) [\(album)]", category: "Music")
        lastLoggedTrack = dedupKey
    }

    // MARK: - Setup & Scheduling

    private func setupFallbackTimer() {
        let timer = DispatchSource.makeTimerSource(queue: backgroundQueue)
        timer.schedule(deadline: .now() + currentCheckInterval, repeating: currentCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isTracking else { return }
            self.fetchNowPlayingInfo()
        }
        timer.activate()
        self.timer = timer
    }

    private func scheduleCheck(after delay: TimeInterval, reason: String) {
        backgroundQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.fetchNowPlayingInfo()
        }
    }
}
