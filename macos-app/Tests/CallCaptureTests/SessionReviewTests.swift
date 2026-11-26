import Foundation
import Testing
@testable import CallCapture

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cc-review-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeTranscript(_ lines: [TranscriptLine], to url: URL) throws {
    try JSONEncoder().encode(lines).write(to: url)
}

@Suite("Transcript document")
struct TranscriptDocumentTests {
    @Test("decodes the worker JSON, including null speakers")
    func decodes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s_transcript.json")
        try Data("""
        [{"start": 0.0, "end": 2.5, "text": "Привіт", "speaker": "You"},
         {"start": 2.5, "end": 5.0, "text": "Hello", "speaker": null}]
        """.utf8).write(to: url)
        let lines = try TranscriptDocument.load(path: url.path)
        #expect(lines == [TranscriptLine(start: 0, end: 2.5, text: "Привіт", speaker: "You"),
                          TranscriptLine(start: 2.5, end: 5, text: "Hello", speaker: nil)])
    }

    @Test("a damaged file throws instead of showing an empty transcript")
    func damaged() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bad.json")
        try Data("{not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try TranscriptDocument.load(path: url.path) }
    }

    @Test("line lookup returns the last line that started at or before the time")
    func lookup() {
        let lines = [TranscriptLine(start: 1, end: 3, text: "a", speaker: nil),
                     TranscriptLine(start: 3, end: 6, text: "b", speaker: nil),
                     TranscriptLine(start: 10, end: 12, text: "c", speaker: nil)]
        #expect(TranscriptDocument.lineIndex(at: 0.5, in: lines) == nil)
        #expect(TranscriptDocument.lineIndex(at: 1, in: lines) == 0)
        #expect(TranscriptDocument.lineIndex(at: 4, in: lines) == 1)
        #expect(TranscriptDocument.lineIndex(at: 8, in: lines) == 1)
        #expect(TranscriptDocument.lineIndex(at: 99, in: lines) == 2)
        #expect(TranscriptDocument.lineIndex(at: 1, in: []) == nil)
    }
}

@Suite("Speaker names")
struct SpeakerNamesTests {
    @Test("whole labels only: renaming Speaker 1 leaves Speaker 10 alone")
    func wholeLabel() {
        let names = SpeakerNames().renamed("Speaker 1", to: "Олена")
        #expect(names.apply(to: "Speaker 1 and Speaker 10 met Speaker 1.")
                == "Олена and Speaker 10 met Олена.")
    }

    @Test("replacement is single-pass, so swapped names never chain")
    func noChaining() {
        let names = SpeakerNames().renamed("Speaker 1", to: "Speaker 2").renamed("Speaker 2", to: "Ann")
        #expect(names.apply(to: "**Speaker 1:** hi **Speaker 2:** yo") == "**Speaker 2:** hi **Ann:** yo")
    }

    @Test("a plain-word label is replaced only in speaker positions, never in prose")
    func structuralOnly() {
        let names = SpeakerNames().renamed("You", to: "Bo")
        let note = """
        ---
        participants:
          - You
        ---
        You should ship it. Thank You.
        | You | 50% |
        `[0.0s - 1.0s]` **You:** You said yes
        """
        let expected = """
        ---
        participants:
          - Bo
        ---
        You should ship it. Thank You.
        | Bo | 50% |
        `[0.0s - 1.0s]` **Bo:** You said yes
        """
        #expect(names.apply(to: note) == expected)
    }

    @Test("frontmatter written with CRLF line endings is renamed too")
    func crlf() {
        let names = SpeakerNames().renamed("You", to: "Bo")
        #expect(names.apply(to: "participants:\r\n  - You\r\n  - Speaker 1\r\n") == "participants:\r\n  - Bo\r\n  - Speaker 1\r\n")
    }

    @Test("display falls back to the original label; blank names remove the mapping")
    func displayAndRemove() {
        var names = SpeakerNames().renamed("Speaker A", to: "  Max  ")
        #expect(names.display("Speaker A") == "Max")
        #expect(names.display("Speaker B") == "Speaker B")
        #expect(names.display(nil) == nil)
        names = names.renamed("Speaker A", to: "   ")
        #expect(names.display("Speaker A") == "Speaker A")
        #expect(names.isEmpty)
    }

    @Test("names are single-line and length-capped")
    func sanitized() {
        let names = SpeakerNames().renamed("Speaker 1", to: "Ann\nLee" + String(repeating: "x", count: 200))
        let name = names.display("Speaker 1") ?? ""
        #expect(!name.contains("\n"))
        #expect(name.count == SpeakerNames.maxNameLength)
    }

    @Test("applies names to transcript lines without touching text")
    func lines() {
        let names = SpeakerNames().renamed("You", to: "Bo")
        let out = names.applied(to: [TranscriptLine(start: 0, end: 1, text: "You said", speaker: "You")])
        #expect(out == [TranscriptLine(start: 0, end: 1, text: "You said", speaker: "Bo")])
    }

    @Test("saves beside the audio and loads back; a missing sidecar is empty")
    func persistence() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("rec.wav").path
        #expect(try SpeakerNames.load(audioPath: audio).isEmpty)
        let names = SpeakerNames().renamed("Speaker 2", to: "Ірина")
        try names.save(audioPath: audio)
        #expect(SpeakerNames.sidecarPath(audioPath: audio) == dir.appendingPathComponent("rec_speakers.json").path)
        #expect(try SpeakerNames.load(audioPath: audio) == names)
    }
}

@Suite("Session search")
struct SessionSearchTests {
    private func session(_ id: String, title: String, dir: URL,
                         lines: [TranscriptLine] = [], notes: String? = nil,
                         names: SpeakerNames = SpeakerNames()) throws -> SearchableSession {
        var transcriptPath: String?
        if !lines.isEmpty {
            let url = dir.appendingPathComponent("\(id)_transcript.json")
            try writeTranscript(lines, to: url)
            transcriptPath = url.path
        }
        var notesPath: String?
        if let notes {
            let url = dir.appendingPathComponent("\(id)_notes.md")
            try Data(notes.utf8).write(to: url)
            notesPath = url.path
        }
        return SearchableSession(id: id, title: title, transcriptPath: transcriptPath,
                                 notesPath: notesPath, names: names)
    }

    @Test("Cyrillic matches case-insensitively and carries the line time")
    func cyrillic() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try session("a", title: "Синк", dir: dir, lines: [
            TranscriptLine(start: 1, end: 2, text: "Обговорили бюджет", speaker: "You"),
            TranscriptLine(start: 42, end: 45, text: "Реліз у ПʼЯТНИЦЮ", speaker: "Speaker 1"),
        ])
        let hits = SessionSearch.search("пʼятницю", in: [s])
        #expect(hits.count == 1)
        #expect(hits.first?.sessionID == "a")
        #expect(hits.first?.time == 42)
        #expect(hits.first?.excerpt.contains("Speaker 1") == true)
    }

    @Test("title hits come first, renamed speakers are searchable, notes skip transcript duplicates")
    func titleNamesNotes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = SpeakerNames().renamed("Speaker 1", to: "Olena")
        let s = try session("b", title: "Olena weekly", dir: dir,
                            lines: [TranscriptLine(start: 5, end: 6, text: "budget", speaker: "Speaker 1")],
                            notes: "## Summary\n- Olena owns pricing\n`[5.0s - 6.0s]` **Speaker 1:** budget\n",
                            names: names)
        let hits = SessionSearch.search("olena", in: [s])
        #expect(hits.map(\.time) == [nil, 5, nil])
        #expect(hits[0].excerpt == "Olena weekly")
        #expect(hits[1].excerpt.hasPrefix("Olena:"))
        #expect(hits[2].excerpt == "- Olena owns pricing")
    }

    @Test("short queries return nothing; hits per session are capped; excerpts are bounded")
    func limits() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let long = String(repeating: "word ", count: 100) + "needle" + String(repeating: " tail", count: 100)
        let lines = (0..<20).map { TranscriptLine(start: Double($0), end: Double($0) + 1, text: long, speaker: nil) }
        let s = try session("c", title: "x", dir: dir, lines: lines)
        #expect(SessionSearch.search("n", in: [s]).isEmpty)
        let hits = SessionSearch.search("needle", in: [s])
        #expect(hits.count == SessionSearch.maxHitsPerSession)
        #expect(hits.allSatisfy { $0.excerpt.contains("needle") && $0.excerpt.count <= SessionSearch.excerptLength + 2 })
        #expect(Set(hits.map(\.id)).count == hits.count)
    }

    @Test("a date query still finds the session, shown by its title")
    func dateMatch() {
        let s = SearchableSession(id: "f", title: "Planning", transcriptPath: nil, notesPath: nil,
                                  names: SpeakerNames(), dateText: "Nov 26, 2026 at 10:00")
        #expect(SessionSearch.search("nov 26", in: [s]).map(\.excerpt) == ["Planning"])
    }

    @Test("a missing or damaged transcript does not hide other sessions")
    func damagedFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = SearchableSession(id: "d", title: "nothing", transcriptPath: dir.appendingPathComponent("gone.json").path,
                                       notesPath: nil, names: SpeakerNames())
        let ok = try session("e", title: "fine", dir: dir, lines: [TranscriptLine(start: 3, end: 4, text: "rollback plan", speaker: nil)])
        #expect(SessionSearch.search("rollback", in: [broken, ok]).map(\.sessionID) == ["e"])
    }
}
