import Foundation

/// A recording start or stop the app is working through.
enum RecordingTransition: String, Sendable {
    case starting
    case stopping
}

/// The recording state the web UI shows and the events stream reports.
enum RecordingPhase: String, Sendable {
    case idle, starting, recording, stopping, processing

    static func derive(state: AppState, transition: RecordingTransition?) -> RecordingPhase {
        switch transition {
        case .starting: return .starting
        case .stopping: return .stopping
        case nil: break
        }
        switch state {
        case .recording: return .recording
        case .transcribing: return .processing
        case .idle, .error: return .idle
        }
    }
}

/// The Record/Stop button: what pressing it does, and why it can't be pressed now.
struct RecordingButton: Equatable, Sendable {
    let action: RecordingTransition
    let refusal: RecordingRequestError?

    var enabled: Bool { refusal == nil }

    /// Shown under a disabled button; a start or stop in progress speaks for itself.
    var reason: String? {
        guard let refusal else { return nil }
        if case .inTransition = refusal { return nil }
        return refusal.message
    }

    static func current(state: AppState, transition: RecordingTransition?, livePreparing: Bool) -> RecordingButton {
        let action: RecordingTransition = state == .recording ? .stopping : .starting
        return RecordingButton(
            action: action,
            refusal: RecordingRequestError.check(action, state: state, transition: transition, livePreparing: livePreparing))
    }
}

/// Everything the API reports about recording, in one value.
struct RecordingStatus: Equatable, Sendable {
    let phase: RecordingPhase
    let playbackBlocked: Bool
    let button: RecordingButton
    let problem: String?

    /// The phase and the button follow `state` and the transition, as the menu does; the
    /// playback block is reported on its own, so a failed stop (tap maybe still running)
    /// keeps playback off without pretending a recording can be stopped.
    static func make(
        state: AppState, playbackBlocked: Bool, transition: RecordingTransition?, livePreparing: Bool,
        lastError: String?
    ) -> RecordingStatus {
        RecordingStatus(
            phase: RecordingPhase.derive(state: state, transition: transition),
            playbackBlocked: state == .recording || playbackBlocked || transition != nil,
            button: RecordingButton.current(state: state, transition: transition, livePreparing: livePreparing),
            problem: state == .error ? lastError : nil)
    }
}

/// Why a recording start or stop can't happen now. The menu's Record button and the
/// web's are both `RecordingButton.current`, which asks this, so they refuse the same things.
enum RecordingRequestError: Error, Equatable, Sendable {
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
            guard state == .recording else { return .notRecording }
            // The menu disables its whole button while the live model downloads.
            return livePreparing ? .livePreparing : nil
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
