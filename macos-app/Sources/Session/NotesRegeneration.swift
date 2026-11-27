import Foundation

/// What a Regenerate AI notes run leaves in the session record (`AppModel.regenerateNotes`).
///
/// The transcript, its path, the engine and the transcription cost are never touched: the
/// run only remade the notes, the analysis and their processing cost. A failure or a
/// cancel puts the status back as it was, never `error`: that status turns the run button
/// into Retry, a paid re-transcription, while the transcript and the earlier notes are fine.
enum NotesRegeneration {
    /// Shown for the run while it goes (`AppActivity.processingStage`).
    static let stage = "Regenerating notes"
    static let failurePrefix = "AI notes weren't regenerated; the earlier notes are kept."
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

    /// The session as it was before the run, with why it failed at the top of its warnings.
    /// `advise` adds what to do, for reasons that don't already say (a crash, a timeout).
    static func recordFailure(_ reason: String, advise: Bool, previous: Session, in sessions: SessionManager) {
        sessions.updateSessionWarning(
            id: previous.id, message: failureWarning(reason, advise: advise, previous: previous.warningMessage))
        restore(previous, in: sessions)
    }

    /// A cancelled run: the status and last error go back to what they were.
    static func restore(_ previous: Session, in sessions: SessionManager) {
        sessions.updateSessionStatus(id: previous.id, status: previous.status, errorMessage: previous.errorMessage)
    }

    /// The failure line, then the earlier warnings (which still describe the kept notes),
    /// minus any earlier failure line so repeated failures don't pile up.
    static func failureWarning(_ reason: String, advise: Bool, previous: String?) -> String {
        let line = [failurePrefix, sentence(reason), advise ? retryAdvice : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let kept = (previous ?? "").components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix(failurePrefix) }
        return ([line] + kept).joined(separator: "\n")
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
