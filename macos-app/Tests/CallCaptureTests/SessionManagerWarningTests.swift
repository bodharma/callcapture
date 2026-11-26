import Foundation
import Testing
@testable import CallCapture

@Suite("Session warnings")
struct SessionManagerWarningTests {
    @Test("a job warning is stored, reloaded with the session, and cleared with nil")
    func roundTrip() throws {
        let path = NSTemporaryDirectory() + "cc-warn-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let manager = SessionManager(database: try AppDatabase(path: path))
        let session = manager.createSession(sourceApp: "Synthetic")
        #expect(manager.session(id: session.id)?.warningMessage == nil)

        let message = "AI notes and sentiment skipped: offline. Re-process when online to generate them."
        manager.updateSessionWarning(id: session.id, message: message)
        #expect(manager.session(id: session.id)?.warningMessage == message)
        #expect(SessionManager(database: try AppDatabase(path: path)).session(id: session.id)?.warningMessage == message)

        manager.updateSessionWarning(id: session.id, message: nil)
        #expect(manager.session(id: session.id)?.warningMessage == nil)
        manager.finalizeSession()
    }
}
