import Foundation

struct SearchableSession: Sendable {
    let id: String
    let title: String
    let transcriptPath: String?
    let notesPath: String?
    let names: SpeakerNames
    /// Formatted start date, so "Nov 26" still finds sessions like the old title filter did.
    var dateText = ""

    init(id: String, title: String, transcriptPath: String?, notesPath: String?,
         names: SpeakerNames, dateText: String = "") {
        (self.id, self.title, self.transcriptPath, self.notesPath) = (id, title, transcriptPath, notesPath)
        (self.names, self.dateText) = (names, dateText)
    }

    /// Reads the session's speaker-name sidecar; call off the main thread.
    init(_ session: Session) {
        self.init(id: session.id, title: session.title,
                  transcriptPath: session.transcriptRawPath, notesPath: session.transcriptMarkdownPath,
                  names: (try? SpeakerNames.load(audioPath: session.audioPath)) ?? SpeakerNames(),
                  dateText: session.startedAt.formatted(date: .abbreviated, time: .shortened))
    }
}

struct SearchHit: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let title: String
    /// Transcript position in seconds; nil for title and note hits.
    let time: Double?
    let excerpt: String
}

/// Case- and diacritic-insensitive scan over titles, transcripts and notes.
/// ponytail: linear file scan per query, fine for a personal archive; add a GRDB FTS5
/// index if searches over thousands of sessions get slow.
enum SessionSearch {
    static let minQueryLength = 2
    static let maxHitsPerSession = 5
    static let maxHits = 200
    static let excerptLength = 160

    /// Non-isolated async: runs off the main actor and stops when the calling task is cancelled.
    static func search(_ query: String, sessions: [Session]) async -> [SearchHit] {
        search(query, in: sessions.lazy.prefix { _ in !Task.isCancelled }.map(SearchableSession.init))
    }

    static func search(_ query: String, in sessions: [SearchableSession]) -> [SearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= minQueryLength else { return [] }
        var hits: [SearchHit] = []
        for session in sessions {
            guard hits.count < maxHits, !Task.isCancelled else { break }
            let found = matches(query, in: session).prefix(maxHitsPerSession)
            hits += found.enumerated().map { index, match in
                SearchHit(id: "\(session.id)#\(index)", sessionID: session.id, title: session.title,
                          time: match.time, excerpt: match.excerpt)
            }
        }
        return Array(hits.prefix(maxHits))
    }

    private static func matches(_ query: String, in session: SearchableSession) -> [(time: Double?, excerpt: String)] {
        var found: [(time: Double?, excerpt: String)] = []
        if let range = find(query, in: session.title) {
            found.append((nil, excerpt(session.title, around: range)))
        } else if find(query, in: session.dateText) != nil {
            found.append((nil, session.title))
        }
        // A damaged or missing file only hides that file's hits.
        let lines = session.transcriptPath.flatMap { try? TranscriptDocument.load(path: $0) } ?? []
        for line in session.names.applied(to: lines) {
            let text = line.speaker.map { "\($0): \(line.text)" } ?? line.text
            if let range = find(query, in: text) { found.append((line.start, excerpt(text, around: range))) }
            if found.count >= maxHitsPerSession { return found }
        }
        let notes = session.notesPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        for line in session.names.apply(to: notes).components(separatedBy: .newlines) {
            // ponytail: transcript lines rendered into the note ("`[1.0s - 2.0s]` ...") are
            // already covered above with their time; skip them by their fixed prefix.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("`["), let range = find(query, in: trimmed) else { continue }
            found.append((nil, excerpt(trimmed, around: range)))
            if found.count >= maxHitsPerSession { break }
        }
        return found
    }

    private static func find(_ query: String, in text: String) -> Range<String.Index>? {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    }

    /// Up to `excerptLength` characters centred on the match, with ellipses where cut.
    private static func excerpt(_ text: String, around range: Range<String.Index>) -> String {
        guard text.count > excerptLength else { return text }
        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let matchLength = text.distance(from: range.lowerBound, to: range.upperBound)
        let lead = max(0, min(matchStart - (excerptLength - matchLength) / 2, text.count - excerptLength))
        let start = text.index(text.startIndex, offsetBy: lead)
        let end = text.index(start, offsetBy: excerptLength)
        return (lead > 0 ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}
