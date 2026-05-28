import Foundation
import Testing
@testable import CallCapture

@Suite("SessionManager.deleteSession")
struct SessionManagerDeleteTests {

    private func makeStubFiles(at base: URL) throws -> [URL] {
        // base = .../<uuid>.wav (the session's audioPath).
        let baseNoExt = base.deletingPathExtension()
        let urls: [URL] = [
            base,                                                           // mixed wav
            baseNoExt.appendingPathExtension("wav.mic"),                    // placeholder, not used
            URL(fileURLWithPath: baseNoExt.path + "_mic.wav"),              // mic stem
            URL(fileURLWithPath: baseNoExt.path + "_system.wav"),           // system stem
            URL(fileURLWithPath: baseNoExt.path + "_system_diarization.json"),
            URL(fileURLWithPath: baseNoExt.path + "_transcript.json"),
            URL(fileURLWithPath: baseNoExt.path + "_notes.md"),
            URL(fileURLWithPath: baseNoExt.path + "_analysis.json"),
        ]
        // Drop the placeholder before writing.
        let kept = urls.filter { !$0.lastPathComponent.contains("wav.mic") }
        for url in kept {
            try? FileManager.default.removeItem(at: url)
            try Data("stub".utf8).write(to: url)
        }
        return kept
    }

    @Test("removes the DB row, the audio files, the stems, and the sidecars")
    func deletesEverything() throws {
        let dbPath = NSTemporaryDirectory() + "cc-del-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try AppDatabase(path: dbPath)
        let manager = SessionManager(database: db)

        let session = manager.createSession(sourceApp: "Test", recordingType: .callMeeting)

        // Seed every sibling file the deleter is expected to clean up.
        let audioURL = URL(fileURLWithPath: session.audioPath)
        try FileManager.default.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let files = try makeStubFiles(at: audioURL)
        // Record DB-tracked sidecars (transcript / notes / analysis) so the
        // deleter picks them up via the record fields.
        let baseNoExt = audioURL.deletingPathExtension().path
        manager.updateSessionPaths(
            id: session.id,
            rawTranscriptPath: baseNoExt + "_transcript.json",
            markdownPath: baseNoExt + "_notes.md",
            engineUsed: "local_whisper"
        )
        manager.updateAnalysisPath(
            id: session.id,
            analysisPath: baseNoExt + "_analysis.json"
        )

        for f in files {
            #expect(FileManager.default.fileExists(atPath: f.path))
        }

        manager.deleteSession(id: session.id)

        #expect(manager.session(id: session.id) == nil)
        for f in files {
            #expect(FileManager.default.fileExists(atPath: f.path) == false,
                    "leftover file: \(f.lastPathComponent)")
        }
    }

    @Test("missing files and missing rows are no-ops")
    func tolerantOfMissingThings() throws {
        let dbPath = NSTemporaryDirectory() + "cc-del-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try AppDatabase(path: dbPath)
        let manager = SessionManager(database: db)

        // Missing id — no crash, no throw, no row created.
        manager.deleteSession(id: "does-not-exist")
        #expect(manager.session(id: "does-not-exist") == nil)

        // Real session whose files never existed on disk.
        let session = manager.createSession(sourceApp: "Test", recordingType: .voiceMemo)
        manager.deleteSession(id: session.id)
        #expect(manager.session(id: session.id) == nil)
    }
}
