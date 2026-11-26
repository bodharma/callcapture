import Foundation
import Testing

@testable import CallCapture

@Suite("Session export and vault paths")
struct SessionExportTests {
    // Mid-month at noon UTC: the same month in every time zone.
    private let date = Date(timeIntervalSince1970: 1_773_576_000)  // 2026-03-15 12:00 UTC

    @Test("a configured vault gets the expanded folder pattern")
    func vaultFolder() {
        let url = SessionExport.vaultDirectory(
            startedAt: date, vault: "/Vault", folderPattern: "_meetings/{YYYY-MM}/", outputDirectory: "/Out")
        #expect(url.path == "/Vault/_meetings/2026-03")
    }

    @Test("without a vault, notes go to <output>/exports")
    func outputFallback() {
        let url = SessionExport.vaultDirectory(
            startedAt: date, vault: "", folderPattern: "_meetings/{YYYY-MM}/", outputDirectory: "/Out")
        #expect(url.path == "/Out/exports")
    }

    @Test("date tokens expand; unknown text stays")
    func folderPattern() {
        #expect(SessionExport.resolvedFolderPattern("{YYYY}/{MM}/notes", date: date) == "2026/03/notes")
        #expect(SessionExport.resolvedFolderPattern("plain", date: date) == "plain")
    }

    @Test("json exports the transcript, md and txt the note")
    func sourcePaths() {
        let session = Session(
            id: "x", title: "t", sourceApp: "a", startedAt: date, audioPath: "/a.wav",
            transcriptRawPath: "/a_transcript.json", transcriptMarkdownPath: "/a_notes.md", status: "transcribed")
        #expect(SessionExport.sourcePath(for: .json, session: session) == "/a_transcript.json")
        #expect(SessionExport.sourcePath(for: .md, session: session) == "/a_notes.md")
        #expect(SessionExport.sourcePath(for: .txt, session: session) == "/a_notes.md")
    }
}
