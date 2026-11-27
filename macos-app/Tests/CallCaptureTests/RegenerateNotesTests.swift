import Foundation
import GRDB
import Testing

@testable import CallCapture

/// Regenerate AI notes: the pure guard (`RegenerateNotesPolicy`), the worker request, and
/// what a finished, failed, cancelled or interrupted run leaves in the session record.
@Suite struct RegenerateNotesPolicyTests {
    private static func session(_ status: String) -> Session {
        Session(
            id: "S1", title: "Weekly sync", sourceApp: "Zoom", startedAt: Date(timeIntervalSince1970: 0),
            audioPath: "/nonexistent/S1.wav", transcriptRawPath: "/nonexistent/S1_transcript.json",
            engineUsed: "remote", status: status)
    }

    private static func problem(
        _ status: String, saved: Bool = true, _ activity: AppActivity = AppActivity()
    ) -> RegenerateNotesPolicy.Problem? {
        RegenerateNotesPolicy.problem(for: session(status), transcriptSaved: saved, activity: activity)
    }

    private static let busy = { (message: String) in RegenerateNotesPolicy.Problem(code: "busy", message: message) }
    private static let stopFirst = busy("Stop the recording before processing a session.")
    private static let otherRun = busy("Another session is being processed. Try again when it finishes.")

    @Test(arguments: ["transcribed", "error", "failed", "completed", "interrupted"])
    func aSavedTranscriptIsEnoughOnAnIdleApp(status: String) {
        #expect(Self.problem(status) == nil)
    }

    @Test func noSavedTranscriptMeansNothingToRegenerate() {
        #expect(Self.problem("completed", saved: false)
            == RegenerateNotesPolicy.Problem(
                code: "no_transcript", message: "This session has no saved transcript yet. Transcribe it first."))
    }

    @Test(arguments: [
        AppActivity(state: .recording),
        AppActivity(state: .idle, playbackBlocked: true),
        AppActivity(state: .idle, transition: .starting),
        AppActivity(state: .recording, transition: .stopping),
    ])
    func aRecordingOrAStartOrStopBlocksIt(activity: AppActivity) {
        #expect(Self.problem("transcribed", activity) == Self.stopFirst)
    }

    @Test func anotherRunBlocksIt() {
        #expect(Self.problem("transcribed", AppActivity(state: .transcribing)) == Self.otherRun)
    }

    /// The page folds a shared reason into one line, so both policies must say it with the same words.
    @Test func bothPoliciesShareTheirBlockReasons() {
        let recording = AppActivity(state: .recording)
        let running = AppActivity(state: .transcribing)
        #expect(Self.problem("transcribed", recording)?.message == SessionBlockReason.stopRecording)
        #expect(Self.problem("transcribed", running)?.message == SessionBlockReason.anotherRun)
        let session = Self.session("transcribed")
        #expect(ReprocessPolicy.problem(for: session, activity: recording) == SessionBlockReason.stopRecording)
        #expect(ReprocessPolicy.problem(for: session, activity: running) == SessionBlockReason.anotherRun)
    }

    @Test func theSessionsOwnRunSaysSo() {
        #expect(Self.problem("transcribing", AppActivity(state: .transcribing))
            == Self.busy("This session is being processed. Try again when it finishes."))
    }

    @Test func aSessionStillRecordingSaysSo() {
        #expect(Self.problem("recording", saved: false, AppActivity(state: .recording, recordingSessionID: "S1"))
            == Self.busy("AI notes can't be regenerated while this session is recording."))
    }

    @Test func offlineBlocksOnlyACloudNotesModelAndComesLast() {
        let cloud = AppActivity(isOnline: false, notesProvider: .openrouter)
        let reason = "Offline — regenerating AI notes needs an internet connection. A local notes model works offline."
        #expect(NetworkPolicy.notesBlockReason(provider: .openrouter, isOnline: false) == reason)
        #expect(Self.problem("transcribed", cloud) == RegenerateNotesPolicy.Problem(code: "offline", message: reason))
        // The session was transcribed in the cloud, but nothing is transcribed now.
        #expect(Self.problem("transcribed", AppActivity(isOnline: false, notesProvider: .local)) == nil)
        #expect(Self.problem("transcribed", AppActivity(isOnline: true, notesProvider: .openrouter)) == nil)
        #expect(Self.problem("transcribed", AppActivity(state: .recording, isOnline: false)) == Self.stopFirst)
        #expect(Self.problem("transcribed", saved: false, cloud)?.code == "no_transcript")
    }

    @Test func aCloudNotesModelNeedsItsKeyFirst() {
        let noKey = RegenerateNotesPolicy.Problem(
            code: "no_api_key", message: "Add an OpenRouter API key in Settings → AI notes to regenerate notes.")
        #expect(Self.problem("transcribed", AppActivity(notesProvider: .openrouter, notesKeySaved: false)) == noKey)
        #expect(Self.problem("transcribed", AppActivity(notesProvider: .local, notesKeySaved: false)) == nil)
        // A missing key outlasts a lost connection, so it is said first.
        #expect(Self.problem("transcribed", AppActivity(isOnline: false, notesProvider: .openrouter, notesKeySaved: false))
            == noKey)
        #expect(Self.problem("transcribed", AppActivity(state: .transcribing, notesKeySaved: false)) == Self.otherRun)
        #expect(Self.problem("transcribed", saved: false, AppActivity(notesKeySaved: false))?.code == "no_transcript")
    }

    @Test func theFileCheckingOverloadLooksForTheTranscript() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("cc-regen-\(UUID().uuidString).json").path
        var session = Self.session("transcribed")
        session.transcriptRawPath = path
        #expect(RegenerateNotesPolicy.problem(for: session, activity: AppActivity())?.code == "no_transcript")
        try Data("[]".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(RegenerateNotesPolicy.problem(for: session, activity: AppActivity()) == nil)
        session.transcriptRawPath = nil
        #expect(RegenerateNotesPolicy.problem(for: session, activity: AppActivity())?.code == "no_transcript")
    }

    @Test func theStageIsShownOnlyForTheSessionBeingProcessed() {
        let running = AppActivity(state: .transcribing, processingStage: NotesRegeneration.stage)
        #expect(NotesRegeneration.stage == "Regenerating notes")
        #expect(ProcessingProgress.stage(for: Self.session("transcribing"), activity: running) == "Regenerating notes")
        #expect(ProcessingProgress.stage(for: Self.session("transcribed"), activity: running) == nil)
        let stale = AppActivity(state: .idle, processingStage: NotesRegeneration.stage)
        #expect(ProcessingProgress.stage(for: Self.session("transcribing"), activity: stale) == nil)
        #expect(ProcessingProgress.stage(for: Self.session("transcribing"), activity: AppActivity(state: .transcribing)) == nil)
    }
}

@Suite struct RegenerateNotesRequestTests {
    @Test func theRequestCarriesTheSavedTranscriptAndTheSessionsNotesSettings() throws {
        let path = NSTemporaryDirectory() + "cc-regen-req-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let settings = SettingsManager(database: try AppDatabase(path: path), credentialStore: InMemoryCredentialStore())
        settings.markdownProfile = .obsidian
        settings.llmFallbackRatePer1M = 4.5
        settings.defaultEngine = .localWhisper
        let session = Session(
            id: "S1", title: "t", sourceApp: "Zoom", startedAt: Date(), audioPath: "/rec/S1.wav",
            transcriptRawPath: "/rec/S1_transcript.json", recordingType: "lecture", language: "uk",
            notesLanguage: "en", engineUsed: "remote", status: "transcribed")

        let request = JobRequest.regenerateNotes(session: session, settings: settings)

        #expect(request.command == "regenerate_notes")
        #expect(request.jobId == "S1")
        #expect(request.audioPath == "/rec/S1.wav")
        #expect(request.transcriptPath == "/rec/S1_transcript.json")
        #expect(request.recordingType == "lecture")
        #expect(request.notesLanguage == "en")
        #expect(request.language == "uk")
        #expect(request.engine == "remote")
        #expect(request.markdownProfile == "obsidian")
        #expect(request.llmFallbackRatePer1M == 4.5)

        let encoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(encoded["command"] as? String == "regenerate_notes")
        #expect(encoded["transcript_path"] as? String == "/rec/S1_transcript.json")
        // A transcription request says nothing about a saved transcript.
        let transcribe = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(JobRequest.transcribe(session: session, settings: settings))) as? [String: Any])
        #expect(transcribe["transcript_path"] == nil)
    }
}

/// What each outcome writes, through the real `SessionManager` over a throwaway database.
@Suite struct NotesRegenerationRecordTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cc-regen-\(UUID().uuidString)", isDirectory: true)

    /// A transcribed session whose run has just started (`transcribing`, error cleared).
    private func running(warning: String? = "AI notes failed (cut off); rule-based notes were used.")
        throws -> (SessionManager, Session)
    {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase(path: directory.appendingPathComponent("db.sqlite").path)
        let base = directory.appendingPathComponent("S1").path
        var session = Session(
            id: "S1", title: "Weekly sync", sourceApp: "Zoom", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            audioPath: base + ".wav", transcriptRawPath: base + "_transcript.json",
            transcriptMarkdownPath: base + "_notes.md", analysisPath: base + "_analysis.json",
            engineUsed: "remote", costTranscription: 1.67, costProcessing: 0.001, costCurrency: "USD",
            status: "error")
        session.warningMessage = warning
        session.errorMessage = "Worker crashed"
        try database.dbPool.write { db in try SessionRecord(from: session).insert(db) }
        let manager = SessionManager(database: database)
        manager.updateSessionStatus(id: "S1", status: "transcribing")
        return (manager, session)
    }

    private func result(
        status: String = "completed", warnings: [String] = [], error: String? = nil
    ) -> JobResult {
        JobResult(
            jobId: "S1", status: status, rawTranscriptPath: "/elsewhere/ignored_transcript.json",
            markdownPath: directory.appendingPathComponent("S1_notes.md").path,
            analysisPath: directory.appendingPathComponent("S1_analysis.json").path, durationSec: 11_640,
            costTranscription: 9.99, costProcessing: 0.0123, costCurrency: "USD", warnings: warnings,
            errorMessage: error)
    }

    @Test func aFinishedRunReplacesNotesCostAndWarningButNotTheTranscript() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, before) = try running()

        NotesRegeneration.recordSuccess(result(warnings: ["One.", "Two."]), sessionID: "S1", in: manager)

        let after = try #require(manager.session(id: "S1"))
        #expect(after.status == "transcribed")
        #expect(after.errorMessage == nil)
        #expect(after.transcriptRawPath == before.transcriptRawPath)
        #expect(after.engineUsed == "remote")
        #expect(after.costTranscription == 1.67)
        #expect(after.costProcessing == 0.0123)
        #expect(after.costCurrency == "USD")
        #expect(after.transcriptMarkdownPath == directory.appendingPathComponent("S1_notes.md").path)
        #expect(after.analysisPath == directory.appendingPathComponent("S1_analysis.json").path)
        #expect(after.warningMessage == "One.\nTwo.")
    }

    @Test func aCleanRunClearsTheWarning() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, _) = try running()
        NotesRegeneration.recordSuccess(result(), sessionID: "S1", in: manager)
        #expect(manager.session(id: "S1")?.warningMessage == nil)
    }

    @Test func aFailedRunKeepsTheEarlierNotesAndSaysWhyAmongTheWarnings() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, before) = try running()

        NotesRegeneration.recordFailure(
            "The saved transcript is missing. Process the recording again to transcribe it.",
            advise: false, previous: before, in: manager)

        let after = try #require(manager.session(id: "S1"))
        // Back to how it was: never `error`, whose button would be a paid re-transcription.
        #expect(after.status == "error")
        #expect(after.errorMessage == "Worker crashed")
        #expect(after.transcriptMarkdownPath == before.transcriptMarkdownPath)
        #expect(after.costProcessing == 0.001)
        #expect(after.warningMessage == """
            Regenerating AI notes failed; the previous notes were kept. The saved transcript is missing. \
            Process the recording again to transcribe it.
            AI notes failed (cut off); rule-based notes were used.
            """)
    }

    @Test func notesTheWorkerKeptLeavePathsAndCostAloneAndSayWhy() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, before) = try running()
        let earlier = NotesRegeneration.failureLine("Worker exited with code 1", advise: true)
        manager.updateSessionWarning(id: "S1", message: earlier + "\nAI notes failed (cut off); rule-based notes were used.")
        var kept = result(warnings: ["Regenerating AI notes failed (HTTP 404: model not found); the previous notes were kept."])
        kept.notesKept = true

        NotesRegeneration.recordKept(kept, previous: before, in: manager)

        let after = try #require(manager.session(id: "S1"))
        #expect(after.status == "error")
        #expect(after.errorMessage == "Worker crashed")
        #expect(after.transcriptMarkdownPath == before.transcriptMarkdownPath)
        #expect(after.analysisPath == before.analysisPath)
        #expect(after.costProcessing == 0.001)
        #expect(after.costTranscription == 1.67)
        #expect(after.warningMessage == """
            Regenerating AI notes failed (HTTP 404: model not found); the previous notes were kept.
            AI notes failed (cut off); rule-based notes were used.
            """)
    }

    @Test func theWorkerSaysWhenItKeptTheNotes() throws {
        let decode = { (json: String) in try JSONDecoder().decode(JobResult.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"job_id":"S1","status":"completed","warnings":[],"notes_kept":true}"#).notesKept == true)
        #expect(try decode(#"{"job_id":"S1","status":"completed","warnings":[]}"#).notesKept == nil)
    }

    @Test func anUnexpectedFailureSaysWhatToDoAndReplacesAnEarlierFailureLine() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier = NotesRegeneration.failureLine("Worker exited with code 1.", advise: true) + "\nOld note."
        let (manager, before) = try running(warning: earlier)

        NotesRegeneration.recordFailure("Worker exited with code 9", advise: true, previous: before, in: manager)

        #expect(manager.session(id: "S1")?.warningMessage == """
            Regenerating AI notes failed; the previous notes were kept. Worker exited with code 9. \
            Try Regenerate AI notes again.
            Old note.
            """)
    }

    @Test func aCancelledRunPutsTheSessionBackAsItWas() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, before) = try running()

        NotesRegeneration.restore(before, in: manager)

        let after = try #require(manager.session(id: "S1"))
        #expect(after.status == "error")
        #expect(after.errorMessage == "Worker crashed")
        #expect(after.warningMessage == before.warningMessage)
        #expect(after.costProcessing == 0.001)
    }

    /// A crash mid-run: the launch reconcile finds the row `transcribing` with its transcript.
    @Test func aRunCutShortByAQuitEndsTranscribedNeverCompleted() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, before) = try running()
        try Data("[]".utf8).write(to: URL(fileURLWithPath: try #require(before.transcriptRawPath)))

        let relaunched = SessionManager(
            database: try AppDatabase(path: directory.appendingPathComponent("db.sqlite").path))

        let after = try #require(relaunched.session(id: "S1"))
        #expect(after.status == "transcribed")
        #expect(after.transcriptRawPath == before.transcriptRawPath)
        #expect(after.transcriptMarkdownPath == before.transcriptMarkdownPath)
        #expect(after.costTranscription == 1.67)
    }
}
