import Foundation
import os

/// Everything the local web UI is allowed to ask of the app.
///
/// The HTTP layer never reaches into `AppModel` directly. Requirements are
/// `async` because some of them touch main-actor state (recording state,
/// connectivity, the live meeting, the observed session list); the production
/// backend hops to the main actor only for those.
///
/// File-derived reads (transcript, note, analysis, speaker names, live map)
/// have default implementations below that work from the `Session` record
/// alone, so every backend, including the test fake, runs the same code.
protocol AppBackend: Sendable {
    /// Every session, newest first.
    func sessions() async -> [Session]
    func session(id: String) async -> Session?
    func search(_ q: String) async -> [SearchHit]
    /// Worker transcript lines with their original speaker labels; `[]` before transcription.
    func transcript(id: String) async throws -> [TranscriptLine]
    /// The Markdown note as the worker wrote it (names not applied).
    func note(id: String) async -> String?
    func analysis(id: String) async -> ConversationAnalysis?
    func speakerNames(id: String) async throws -> SpeakerNames
    /// A blank name restores the original label.
    func renameSpeaker(id: String, label: String, name: String) async throws
    /// Removes the session and its files; throws `BackendError.busy` while it is in use.
    func delete(id: String) async throws
    /// Starts processing in the background and returns once it has started; the
    /// session's `status` / `errorMessage` report progress and the outcome.
    /// Throws `.notFound`, or `.busy(reason)` when it cannot start now.
    func reprocess(id: String) async throws
    /// Writes the note (names applied) into the configured vault; returns the new file.
    func saveToVault(id: String) async throws -> URL
    /// The saved live map, or the live one while that session is still recording.
    func liveDocument(id: String) async throws -> ConversationDocument?
    func revealInFinder(id: String) async throws
    func systemStatus() async -> SystemStatus
}

struct SystemStatus: Codable, Equatable, Sendable {
    let online: Bool
    /// True while capture runs (or is starting/stopping): playback would be recorded.
    let recording: Bool
    let version: String
}

enum BackendError: Error, Equatable {
    case notFound
    /// The session is in use (recording or processing); the message says why.
    case busy(String)
    /// There is no note to save or export yet.
    case nothingToSave
}

extension AppBackend {
    func requireSession(_ id: String) async throws -> Session {
        guard let session = await session(id: id) else { throw BackendError.notFound }
        return session
    }

    func search(_ q: String) async -> [SearchHit] {
        guard q.trimmingCharacters(in: .whitespacesAndNewlines).count >= SessionSearch.minQueryLength
        else { return [] }
        let all = await sessions()
        // Reads every transcript and note: keep it off the cooperative pool.
        return (try? await Blocking.run { SessionSearch.search(q, in: all.map(SearchableSession.init)) }) ?? []
    }

    func transcript(id: String) async throws -> [TranscriptLine] {
        try SessionFiles.transcript(of: await requireSession(id))
    }

    func note(id: String) async -> String? {
        await session(id: id).flatMap(SessionFiles.note(of:))
    }

    func analysis(id: String) async -> ConversationAnalysis? {
        await session(id: id).flatMap(SessionFiles.analysis(of:))
    }

    func speakerNames(id: String) async throws -> SpeakerNames {
        SessionFiles.speakerNames(of: try await requireSession(id))
    }

    /// Over a damaged sidecar this writes a fresh one, as a rename in the detail view does.
    func renameSpeaker(id: String, label: String, name: String) async throws {
        let session = try await requireSession(id)
        try SessionFiles.speakerNames(of: session).renamed(label, to: name).save(audioPath: session.audioPath)
    }

    func liveDocument(id: String) async throws -> ConversationDocument? {
        try SavedLiveMap.load(audioPath: await requireSession(id).audioPath)
    }
}

/// Reads of the files a `Session` record points at. Paths only ever come from
/// the record, never from a request.
enum SessionFiles {
    private static let logger = Logger(subsystem: "com.callcapture.app", category: "SessionFiles")

    /// A missing or damaged `_speakers.json` reads as no names (logged), like the
    /// detail view, so one bad sidecar never hides the transcript or exports.
    static func speakerNames(of session: Session) -> SpeakerNames {
        do {
            return try SpeakerNames.load(audioPath: session.audioPath)
        } catch {
            logger.error(
                "Speaker names unreadable for session \(session.id); using none: \(error.localizedDescription)")
            return SpeakerNames()
        }
    }

    /// `[]` when the session has no transcript yet; throws when the file is unreadable.
    static func transcript(of session: Session) throws -> [TranscriptLine] {
        guard let path = session.transcriptRawPath, FileManager.default.fileExists(atPath: path)
        else { return [] }
        return try TranscriptDocument.load(path: path)
    }

    static func note(of session: Session) -> String? {
        session.transcriptMarkdownPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

    static func analysis(of session: Session) -> ConversationAnalysis? {
        session.analysisPath.flatMap(ConversationAnalysis.load(fromPath:))
    }

    static func exists(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}
