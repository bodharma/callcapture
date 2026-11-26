import Foundation
import Testing
@testable import CallCapture

@Suite("Safe session note exports")
struct SessionNoteExportTests {
    @Test("same titles and repeated exports preserve existing user content")
    func collisions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.md")
        try Data("original".utf8).write(to: source)
        let output = directory.appendingPathComponent("exports")
        let first = try SessionNoteExport.copy(source: source, directory: output, title: "Same/title", sessionID: "session-one")
        try Data("User edits".utf8).write(to: first)
        let second = try SessionNoteExport.copy(source: source, directory: output, title: "Same/title", sessionID: "session-two")
        let repeated = try SessionNoteExport.copy(source: source, directory: output, title: "Same/title", sessionID: "session-one")
        #expect(first != second)
        #expect(first != repeated)
        #expect(try String(contentsOf: first) == "User edits")
        #expect(try String(contentsOf: second) == "original")
        #expect(try String(contentsOf: repeated) == "original")
        #expect(first.deletingLastPathComponent().path == output.path)
    }
}
