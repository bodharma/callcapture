import Foundation

/// Which sessions offer Transcribe / Re-process / Retry, and why it can't run offline.
/// The web shows the reason under a disabled button, before any click, as the
/// native detail view did; the API refuses with the same words.
enum ReprocessPolicy {
    static let processableStatuses: Set<String> = ["completed", "transcribed", "error", "failed", "interrupted"]

    /// Nil when the status has no such button or the engine doesn't need the network.
    static func offlineReason(status: String, engine: String, isOnline: Bool) -> String? {
        guard processableStatuses.contains(status),
            let reason = NetworkPolicy.blockReason(engine: engine, isOnline: isOnline)
        else { return nil }
        return "\(reason) This session uses cloud transcription."
    }
}
