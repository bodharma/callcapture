import Foundation

/// Publishes transcription progress as `progress` events, at most once per `interval`
/// (the last value of a burst always goes out). Silent while nothing is transcribing
/// or no session is known to be.
@MainActor
final class ProgressEventWatcher {
    private var loop: ObservationLoop?
    private var throttle: TrailingThrottle?

    init(
        isActive: @escaping @MainActor () -> Bool, progress: @escaping @MainActor () -> Double,
        sessionID: @escaping @MainActor () -> String?, post: @escaping @Sendable (ServerEvent) -> Void,
        interval: Duration = .milliseconds(250)
    ) {
        throttle = TrailingThrottle(interval: interval) {
            guard isActive(), let id = sessionID() else { return }
            post(.progress(sessionID: id, value: min(max(progress(), 0), 1)))
        }
        loop = ObservationLoop(track: { _ = (isActive(), progress()) }) { [weak self] in
            self?.throttle?.signal()
        }
    }

    func stop() {
        loop?.stop()
        throttle?.cancel()
    }
}
