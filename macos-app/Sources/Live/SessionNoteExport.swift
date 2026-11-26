import Foundation

enum SessionNoteExport {
    static func copy(source: URL, directory: URL, title: String, sessionID: String) throws -> URL {
        try write(Data(contentsOf: source), directory: directory, title: title, sessionID: sessionID)
    }

    /// Writes a new note file; never replaces an existing one (same titles get a numeric suffix).
    static func write(_ data: Data, directory: URL, title: String, sessionID: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let safeTitle = String(title.components(separatedBy: forbidden).joined(separator: "-").prefix(100))
        let safeID = sessionID.components(separatedBy: forbidden).joined(separator: "-")
        let stem = "\(safeTitle.isEmpty ? "Session" : safeTitle)-\(safeID)"
        for index in 0..<1000 {
            let suffix = index == 0 ? "" : "-\(index)"
            let destination = directory.appendingPathComponent("\(stem)\(suffix).md")
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                return destination
            } catch {
                guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
