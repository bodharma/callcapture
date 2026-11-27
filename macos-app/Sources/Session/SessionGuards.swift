import Foundation

/// What the app is doing, as the session guards need it. `AppModel.activity` reads it in
/// one main-actor step; the test fake builds it from its own controls. The guards below
/// decide from this value only, so the API and the fake apply the same rules.
struct AppActivity: Equatable, Sendable {
    var state: AppState = .idle
    var transition: RecordingTransition?
    var playbackBlocked = false
    var isOnline = true
    /// The session being recorded, started or stopped (`SessionManager.currentSession`).
    var recordingSessionID: String?
    /// The engine a session without `engineUsed` is processed with.
    var defaultEngine = TranscriptionEngine.localWhisper.rawValue
    /// The worker's progress for the current run, as reported (not clamped).
    var processingProgress: Double = 0
}

/// Why a session can't be deleted right now. Decided from what the app is doing, not from
/// the stored status alone, so a row left `transcribing` or `recording` by a quit or a
/// failed start can always be deleted.
enum DeletePolicy {
    static let recordingMessage = "Stop the recording before deleting this session."
    static let processingMessage = "This session is being processed. Delete it when that finishes, or cancel it from the menu."

    static func problem(for session: Session, activity: AppActivity) -> String? {
        // A failed stop keeps playback blocked: the tap may still be writing the file.
        let capturing = activity.state == .recording || activity.transition != nil || activity.playbackBlocked
        if capturing, activity.recordingSessionID == session.id { return recordingMessage }
        if activity.state == .transcribing, session.status == "transcribing" { return processingMessage }
        return nil
    }
}

extension ReprocessPolicy {
    /// Why Transcribe / Re-process / Retry can't run now, in the app's words; nil when it can.
    /// Checked in this order: the session's status, a recording, another run, the network.
    static func problem(for session: Session, activity: AppActivity) -> String? {
        guard processableStatuses.contains(session.status) else {
            return "This session can't be processed while it is \(session.status)."
        }
        // Processing takes over AppModel.state; during a recording, or while one starts or
        // stops, that would leave the menu unable to stop the capture (see the Task 5
        // report, pre-review fix #5).
        guard activity.state != .recording, !activity.playbackBlocked, activity.transition == nil else {
            return "Stop the recording before processing a session."
        }
        guard activity.state != .transcribing else {
            return "Another session is being processed. Try again when it finishes."
        }
        let engine = JobRequest.engine(engineUsed: session.engineUsed, defaultEngine: activity.defaultEngine)
        return offlineReason(status: session.status, engine: engine, isOnline: activity.isOnline)
    }

    /// The reason shown under a disabled button, before any click; nil for statuses that
    /// have no such button (the page shows no button to explain).
    static func buttonReason(for session: Session, activity: AppActivity) -> String? {
        guard processableStatuses.contains(session.status) else { return nil }
        return problem(for: session, activity: activity)
    }
}

/// The 0…1 progress shown while the app processes a session.
enum ProcessingProgress {
    static func value(for session: Session, activity: AppActivity) -> Double? {
        guard activity.state == .transcribing, session.status == "transcribing" else { return nil }
        return min(max(activity.processingProgress, 0), 1)
    }
}
