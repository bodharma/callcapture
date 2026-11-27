import Foundation
import OSLog

/// Regenerate AI notes: the notes and analysis remade from the saved transcript, through
/// the transcription job's plumbing (the worker bridge and its progress, `progress` events,
/// the menu's Cancel, quitting). Nothing is transcribed or uploaded.
///
/// The session shows `transcribing` meanwhile, as for Re-process, so every guard treats it
/// as busy. A run cut short by a quit is settled by the launch reconcile as `transcribed`,
/// because the transcript exists. What each outcome records is `NotesRegeneration`.
@available(macOS 14.2, *)
extension AppModel {
    private static let notesLogger = Logger(subsystem: "com.callcapture.app", category: "RegenerateNotes")

    /// Call in the same main-actor step as the `RegenerateNotesPolicy` check: the app and
    /// the row are marked busy before this returns, so a second request is refused.
    @MainActor func startRegeneratingNotes(_ session: Session) {
        state = .transcribing
        lastError = nil
        notice = nil
        processingStage = NotesRegeneration.stage
        sessionManager.updateSessionStatus(id: session.id, status: "transcribing")
        transcriptionTask = Task { [weak self] in
            await self?.regenerateNotes(previous: session)
        }
    }

    /// `previous` is the session as it was before the run: a cancel or a failure puts it back.
    @MainActor private func regenerateNotes(previous: Session) async {
        let request = JobRequest.regenerateNotes(session: previous, settings: settingsManager)
        Self.notesLogger.info("Regenerating notes for session \(previous.id)")
        do {
            // No LLM_OFFLINE here: the policy refused a cloud notes model offline, and a
            // skipped LLM would replace the earlier notes with rule-based ones.
            let result = try await pythonBridge.runJob(request: request, env: notesEnvironment())
            if Task.isCancelled {
                // Cancel terminates the worker, which can still answer with an exit-code error.
                NotesRegeneration.restore(previous, in: sessionManager)
            } else if result.status == "completed", result.notesKept == true {
                // The AI call fell back: the worker left the earlier notes in place.
                NotesRegeneration.recordKept(result, previous: previous, in: sessionManager)
            } else if result.status == "completed" {
                NotesRegeneration.recordSuccess(result, sessionID: previous.id, in: sessionManager)
            } else {
                let reason = result.errorMessage ?? result.warnings.first ?? "The worker stopped without a result."
                Self.notesLogger.error("Regenerating notes failed for session \(previous.id): \(reason)")
                // The worker's own `failed` sentences already say what to do.
                NotesRegeneration.recordFailure(
                    reason, advise: result.status != "failed", previous: previous, in: sessionManager)
            }
        } catch is CancellationError {
            NotesRegeneration.restore(previous, in: sessionManager)
        } catch {
            Self.notesLogger.error("Regenerating notes failed for session \(previous.id): \(error)")
            NotesRegeneration.recordFailure(
                error.localizedDescription, advise: true, previous: previous, in: sessionManager)
        }
        processingStage = nil
        // The session page carries the outcome; the menu goes back to idle, not to an error.
        // A Cancel already set it, and a recording may have started since.
        if state == .transcribing { state = .idle }
    }
}
