import Foundation

/// What a Regenerate AI notes run leaves in the session record (`AppModel.regenerateNotes`).
///
/// The transcript, its path, the engine and the transcription cost are never touched: the
/// run only remade the notes, the analysis and their processing cost. A failure, notes the
/// worker kept (its AI call fell back) or a cancel put the status back as it was, never
/// `error`: that status turns the run button into Retry, a paid re-transcription, while the
/// transcript and the earlier notes are fine.
enum NotesRegeneration {
    /// Shown for the run while it goes (`AppActivity.processingStage`).
    static let stage = "Regenerating notes"
    /// Starts every failure line, the app's and the worker's, so a later one replaces it.
    static let failurePrefix = "Regenerating AI notes failed"
    static let retryAdvice = "Try Regenerate AI notes again."

    /// The new notes and analysis, the new run's processing cost and warnings; `transcribed`.
    static func recordSuccess(_ result: JobResult, sessionID id: String, in sessions: SessionManager) {
        guard let current = sessions.session(id: id) else { return }
        sessions.updateSessionPaths(
            id: id, rawTranscriptPath: current.transcriptRawPath,
            markdownPath: result.markdownPath ?? current.transcriptMarkdownPath, engineUsed: current.engineUsed)
        sessions.updateAnalysisPath(id: id, analysisPath: result.analysisPath ?? current.analysisPath)
        sessions.updateSessionWarning(
            id: id, message: result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n"))
        sessions.updateSessionCost(
            id: id, costTranscription: current.costTranscription, costProcessing: result.costProcessing,
            costCurrency: result.costCurrency ?? current.costCurrency)
        sessions.updateSessionStatus(id: id, status: "transcribed")
    }

    /// The worker's AI call fell back and it left the earlier notes as they were
    /// (`notesKept`): paths and processing cost stay, its warning says why.
    static func recordKept(_ result: JobResult, previous: Session, in sessions: SessionManager) {
        sessions.updateSessionWarning(
            id: previous.id, message: warning(leading: result.warnings, previous: previous.warningMessage))
        restore(previous, in: sessions)
    }

    /// The job itself failed: the session as it was, with why at the top of its warnings.
    /// `advise` adds what to do, for reasons that don't already say (a crash, a timeout).
    static func recordFailure(_ reason: String, advise: Bool, previous: Session, in sessions: SessionManager) {
        sessions.updateSessionWarning(
            id: previous.id,
            message: warning(leading: [failureLine(reason, advise: advise)], previous: previous.warningMessage))
        restore(previous, in: sessions)
    }

    /// A cancelled run: the status and last error go back to what they were.
    static func restore(_ previous: Session, in sessions: SessionManager) {
        sessions.updateSessionStatus(id: previous.id, status: previous.status, errorMessage: previous.errorMessage)
    }

    static func failureLine(_ reason: String, advise: Bool) -> String {
        ["\(failurePrefix); the previous notes were kept.", sentence(reason), advise ? retryAdvice : ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `lines` first, then the earlier warnings (they still describe the kept notes),
    /// minus any earlier failure line so repeated failures don't pile up.
    static func warning(leading lines: [String], previous: String?) -> String? {
        let kept = (previous ?? "").components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix(failurePrefix) }
        let all = lines.filter { !$0.isEmpty } + kept
        return all.isEmpty ? nil : all.joined(separator: "\n")
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
