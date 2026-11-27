import Foundation

/// Export and Save-to-vault logic behind the web API.
enum SessionExport {
    enum Format: String, CaseIterable, Sendable {
        case md, txt, json
    }

    /// The worker writes a Markdown note and a JSON transcript; plain text reuses the note.
    static func sourcePath(for format: Format, session: Session) -> String? {
        switch format {
        case .json: session.transcriptRawPath
        case .md, .txt: session.transcriptMarkdownPath
        }
    }

    /// Export contents with the session's speaker names applied.
    static func data(from path: String, format: Format, names: SpeakerNames) throws -> Data {
        // No names: export the worker's bytes unchanged (keeps nulls and any newer fields).
        if names.isEmpty { return try Data(contentsOf: URL(fileURLWithPath: path)) }
        if format == .json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            return try encoder.encode(names.applied(to: TranscriptDocument.load(path: path)))
        }
        return Data(names.apply(to: try String(contentsOfFile: path, encoding: .utf8)).utf8)
    }

    /// The configured Obsidian vault plus its dated subfolder, or `<output>/exports`
    /// when no vault is set.
    static func vaultDirectory(
        startedAt: Date, vault: String, folderPattern: String, outputDirectory: String
    ) -> URL {
        let (base, subfolder) = vault.isEmpty
            ? (outputDirectory, "exports")
            : (vault, resolvedFolderPattern(folderPattern, date: startedAt))
        return URL(fileURLWithPath: base).appendingPathComponent(subfolder, isDirectory: true)
    }

    /// Writes the note with names applied as a new file in `directory` (never replaces one).
    static func saveNote(
        markdownPath: String, names: SpeakerNames, directory: URL, title: String, sessionID: String
    ) throws -> URL {
        let note = names.apply(to: try String(contentsOfFile: markdownPath, encoding: .utf8))
        return try SessionNoteExport.write(
            Data(note.utf8), directory: directory, title: title, sessionID: sessionID)
    }

    /// Expands date tokens in an Obsidian folder pattern.
    static func resolvedFolderPattern(_ pattern: String, date: Date) -> String {
        let formatter = DateFormatter()
        let replacements: [(String, String)] = [
            ("{YYYY-MM}", "yyyy-MM"),
            ("{YYYY}", "yyyy"),
            ("{MM}", "MM"),
            ("{DD}", "dd"),
        ]
        var result = pattern
        for (token, format) in replacements where result.contains(token) {
            formatter.dateFormat = format
            result = result.replacingOccurrences(of: token, with: formatter.string(from: date))
        }
        return result
    }
}
