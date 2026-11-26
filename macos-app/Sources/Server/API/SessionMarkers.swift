import Foundation

/// A timed point on the meeting tape, taken from a live-map memo.
struct TapeMarker: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case decision, question, note }
    let id: String
    let time: Double
    let kind: Kind
    let text: String
}

/// Markers come only from timed evidence in the live map (spec: "markers only
/// where timed evidence exists"):
/// - decision and question memos, automatic or manual, keep their kind;
/// - other manual memos (typed or edited notes, ideas, actions) become `note`;
/// - automatic idea/action/note memos and pending revision suggestions are skipped.
/// A memo's time is the earliest start of the turns it cites. Memos that cite no
/// turns (notes typed during the meeting) carry no time and are left out.
enum TapeMarkers {
    static func from(_ document: ConversationDocument?) -> [TapeMarker] {
        guard let document else { return [] }
        let starts = Dictionary(
            document.turns.map { ($0.id, $0.start) }, uniquingKeysWith: { first, _ in first })
        return document.topics
            .flatMap(\.memos)
            .compactMap { memo -> TapeMarker? in
                guard memo.suggestedRevisionOf == nil, let kind = kind(of: memo),
                    let time = memo.turnIDs.compactMap({ starts[$0] }).filter(\.isFinite).min(),
                    time >= 0
                else { return nil }
                return TapeMarker(id: memo.id, time: time, kind: kind, text: memo.text)
            }
            .sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }

    private static func kind(of memo: LiveMemo) -> TapeMarker.Kind? {
        switch memo.kind {
        case .decision: .decision
        case .question: .question
        case .idea, .action, .note: memo.manual ? .note : nil
        }
    }
}

/// Read-only access to a session's saved live map (`<audio-base>_live.json`).
///
/// Decodes the file directly instead of going through `LiveMeetingModel`, which
/// would register the loaded instance as the file's single writer.
enum SavedLiveMap {
    static let maxBytes = 100_000_000

    static func path(audioPath: String) -> String {
        (audioPath as NSString).deletingPathExtension + "_live.json"
    }

    /// nil when the session was recorded without the live map.
    static func load(audioPath: String) throws -> ConversationDocument? {
        let path = path(audioPath: audioPath)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(ConversationDocument.self, from: data)
    }
}
