import Foundation

/// Which map a live target resolves to.
enum LiveTargetSource: Equatable, Sendable {
    /// The live meeting controller's model (the meeting being, or just, recorded).
    case active
    /// The session's map saved beside its audio.
    case saved
}

/// How `.current` and `.session(id)` resolve, as pure decisions over the active meeting's
/// state. The production backend and the test fake both use these.
enum LiveTargetPolicy {
    /// For reading. Nil only for `.current` before any meeting has used the live map.
    static func viewSource(_ target: LiveTarget, activeSessionID: String) -> LiveTargetSource? {
        switch target {
        case .current: activeSessionID.isEmpty ? nil : .active
        case .session(let id): activeSessionID == id ? .active : .saved
        }
    }

    /// For actions. `.current` needs a meeting that is still recording; a session's own
    /// meeting stays its one writer, otherwise its saved map must exist.
    static func actionSource(
        _ target: LiveTarget, activeSessionID: String, activeIsRecording: Bool, savedMapExists: Bool
    ) throws -> LiveTargetSource {
        switch target {
        case .current:
            guard activeIsRecording else { throw LiveActionError.noLiveMeeting }
            return .active
        case .session(let id):
            if activeSessionID == id { return .active }
            guard savedMapExists else { throw LiveActionError.notFound }
            return .saved
        }
    }
}
