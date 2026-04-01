import Foundation

/// Manages the active music playback source and switches between them based on user preference.
///
/// AppDelegate owns a single PlaybackSourceManager and interacts with it instead of
/// individual sources directly. The manager persists the chosen mode to UserDefaults
/// and handles clean start/stop transitions when switching.
class PlaybackSourceManager: PlaybackSourceDelegate {

    // MARK: - Properties

    /// The delegate that receives forwarded playback callbacks.
    weak var delegate: PlaybackSourceDelegate?

    /// The currently active playback mode.
    private(set) var currentMode: PlaybackSourceMode

    private let appleMusicSource = AppleMusicSource()
    private lazy var systemNowPlayingSource = SystemNowPlayingSource()
    private var activeSource: (any PlaybackSource)?
    private var isTracking = false

    // MARK: - Init

    init() {
        let stored = UserDefaults.standard.string(forKey: "playbackSourceMode")
        currentMode = PlaybackSourceMode(rawValue: stored ?? "") ?? .appleMusic
    }

    // MARK: - Public Methods

    /// Starts tracking with the current mode's source.
    func startTracking() {
        stopTracking()
        let source: any PlaybackSource = (currentMode == .appleMusic) ? appleMusicSource : systemNowPlayingSource
        source.delegate = self  // NOTE: this requires a workaround — see below
        activeSource = source
        isTracking = true
        source.startTracking()
    }

    /// Stops the active source.
    func stopTracking() {
        activeSource?.stopTracking()
        // Clear delegate to avoid retain issues
        // (set via the concrete type helpers below)
        clearActiveSourceDelegate()
        activeSource = nil
        isTracking = false
    }

    /// Switches to a new mode. If currently tracking, restarts with the new source.
    func switchMode(_ mode: PlaybackSourceMode) {
        guard mode != currentMode else { return }
        let wasTracking = isTracking
        stopTracking()
        currentMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "playbackSourceMode")
        if wasTracking { startTracking() }
    }

    /// Updates the fallback polling interval on the active source.
    func updateCheckInterval(_ interval: TimeInterval) {
        activeSource?.updateCheckInterval(interval)
    }

    // MARK: - PlaybackSourceDelegate (forwarding)

    func playbackSource(_ source: any PlaybackSource, didUpdateTrack track: String, artist: String, album: String, duration: TimeInterval, elapsed: TimeInterval) {
        delegate?.playbackSource(source, didUpdateTrack: track, artist: artist, album: album, duration: duration, elapsed: elapsed)
    }

    func playbackSource(_ source: any PlaybackSource, didUpdateStatus status: String) {
        delegate?.playbackSource(source, didUpdateStatus: status)
    }

    // MARK: - Private Helpers

    private func clearActiveSourceDelegate() {
        if let source = activeSource as? AppleMusicSource {
            source.delegate = nil
        } else if let source = activeSource as? SystemNowPlayingSource {
            source.delegate = nil
        }
    }
}
