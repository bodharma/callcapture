import Foundation
import Testing
@testable import CallCapture

@Suite("SessionManager.updateLanguage")
struct SessionManagerLanguageTests {
    @Test("persists a new language code to the database")
    func persists() throws {
        let path = NSTemporaryDirectory() + "cc-sml-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try AppDatabase(path: path)
        let manager = SessionManager(database: db)

        let session = manager.createSession(sourceApp: "Test", recordingType: .callMeeting)
        #expect(manager.session(id: session.id)?.language == "auto")

        manager.updateLanguage(id: session.id, language: "uk")
        #expect(manager.session(id: session.id)?.language == "uk")
    }

    @Test("unknown id is a no-op and does not crash")
    func unknownId() throws {
        let path = NSTemporaryDirectory() + "cc-sml-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try AppDatabase(path: path)
        let manager = SessionManager(database: db)

        manager.updateLanguage(id: "does-not-exist", language: "uk")
        #expect(manager.session(id: "does-not-exist") == nil)
    }
}
