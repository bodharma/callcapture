import Foundation

/// A recording start or stop the app is working through.
enum RecordingTransition: String, Sendable {
    case starting
    case stopping
}

/// The recording state the web UI shows and the events stream reports.
enum RecordingPhase: String, Sendable {
    case idle, starting, recording, stopping, processing

    static func derive(state: AppState, playbackBlocked: Bool, transition: RecordingTransition?) -> RecordingPhase {
        switch transition {
        case .starting: return .starting
        case .stopping: return .stopping
        case nil: break
        }
        // A failed stop keeps playback blocked: the system tap may still be recording.
        if state == .recording || playbackBlocked { return .recording }
        return state == .transcribing ? .processing : .idle
    }

    /// The system tap records everything the Mac plays, so session playback stays off
    /// from the moment a start begins until the stop has finished.
    var blocksPlayback: Bool {
        switch self {
        case .starting, .recording, .stopping: true
        case .idle, .processing: false
        }
    }
}

/// Why a recording start or stop can't happen now. Mirrors what disables the menu's
/// Record button, so the menu and the web UI refuse the same things.
enum RecordingRequestError: Error, Equatable {
    case alreadyRecording
    case notRecording
    case processing
    case inTransition(RecordingTransition)
    case livePreparing

    static func check(
        _ wanted: RecordingTransition, state: AppState, transition: RecordingTransition?, livePreparing: Bool
    ) -> RecordingRequestError? {
        if let transition { return .inTransition(transition) }
        switch wanted {
        case .starting:
            if state == .recording { return .alreadyRecording }
            if state == .transcribing { return .processing }
            if livePreparing { return .livePreparing }
            return nil
        case .stopping:
            return state == .recording ? nil : .notRecording
        }
    }

    var code: String {
        switch self {
        case .alreadyRecording: "already_recording"
        case .notRecording: "not_recording"
        case .processing: "processing"
        case .inTransition: "busy"
        case .livePreparing: "live_model_downloading"
        }
    }

    var message: String {
        switch self {
        case .alreadyRecording: "A recording is already running."
        case .notRecording: "Nothing is recording."
        case .processing: "A session is being processed. Record again when it finishes, or cancel it from the menu."
        case .inTransition(.starting): "The recording is still starting. Try again in a moment."
        case .inTransition(.stopping): "The recording is still stopping. Try again in a moment."
        case .livePreparing: "The live speech model is downloading. Wait for it or cancel it from the menu."
        }
    }
}
