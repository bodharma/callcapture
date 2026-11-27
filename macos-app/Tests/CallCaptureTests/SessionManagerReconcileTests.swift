import Foundation
import GRDB
import Testing

@testable import CallCapture

/// Launch cleanup: rows a previous run left mid-way (`recording`, `transcribing`) are
/// settled so the web UI never shows a session that can't be re-run or deleted.
@Suite struct SessionManagerReconcileTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cc-reconcile-\(UUID().uuidString)", isDirectory: true)

    private func database(with sessions: [Session]) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase(path: directory.appendingPathComponent("db.sqlite").path)
        try database.dbPool.write { db in
            for session in sessions { try SessionRecord(from: session).insert(db) }
        }
        return database
    }

    private func session(_ id: String, status: String, transcript: String? = nil) -> Session {
        Session(
            id: id, title: id, sourceApp: "Zoom", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            audioPath: directory.appendingPathComponent("\(id).wav").path, transcriptRawPath: transcript,
            status: status)
    }

    @Test func aRunStoppedByQuittingKeepsAnExistingTranscript() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("S1_transcript.json").path
        let database = try database(with: [session("S1", status: "transcribing", transcript: transcript)])
        try Data("[]".utf8).write(to: URL(fileURLWithPath: transcript))

        let reconciled = try #require(SessionManager(database: database).session(id: "S1"))
        #expect(reconciled.status == "transcribed")
        #expect(reconciled.errorMessage == SessionManager.processingStoppedMessage)
    }

    @Test func aRunStoppedByQuittingWithoutATranscriptGoesBackToCompleted() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("gone_transcript.json").path
        let database = try database(with: [
            session("S1", status: "transcribing"),
            session("S2", status: "transcribing", transcript: missing),
        ])

        let manager = SessionManager(database: database)
        for id in ["S1", "S2"] {
            let reconciled = try #require(manager.session(id: id))
            #expect(reconciled.status == "completed", "\(id)")
            #expect(reconciled.errorMessage == SessionManager.processingStoppedMessage, "\(id)")
        }
    }

    @Test func otherRowsAreLeftAlone() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try database(with: [
            session("S1", status: "transcribed"), session("S2", status: "recording"), session("S3", status: "error"),
        ])
        let manager = SessionManager(database: database)
        #expect(manager.session(id: "S1")?.status == "transcribed")
        #expect(manager.session(id: "S2")?.status == "interrupted")
        #expect(manager.session(id: "S3")?.status == "error")
        #expect(manager.session(id: "S1")?.errorMessage == nil)
    }
}
