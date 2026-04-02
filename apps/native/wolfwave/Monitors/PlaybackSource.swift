import Foundation

// MARK: - PlaybackSourceMode

/// The user's chosen music source mode.
enum PlaybackSourceMode: String {
    case appleMusic = "appleMusic"
    case systemNowPlaying = "systemNowPlaying"
}

// MARK: - PlaybackSourceDelegate

/// Delegate protocol for receiving playback updates from any music source.
protocol PlaybackSourceDelegate: AnyObject {
    func playbackSource(
        _ source: any PlaybackSource,
        didUpdateTrack track: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        elapsed: TimeInterval
    )
    func playbackSource(_ source: any PlaybackSource, didUpdateStatus status: String)
    /// Called when the source detects which app is currently playing media.
    /// - Parameter bundleIdentifier: The bundle ID of the playing app, or `nil` if unknown.
    func playbackSource(_ source: any PlaybackSource, didDetectSourceApp bundleIdentifier: String?)
}

extension PlaybackSourceDelegate {
    func playbackSource(_ source: any PlaybackSource, didDetectSourceApp bundleIdentifier: String?) {}
}

// MARK: - PlaybackSource

/// Contract that every music source must satisfy.
protocol PlaybackSource: AnyObject {
    var delegate: PlaybackSourceDelegate? { get set }
    func startTracking()
    func stopTracking()
    func updateCheckInterval(_ interval: TimeInterval)
}
