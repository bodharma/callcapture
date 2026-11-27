import Foundation

/// One segment of the worker's raw transcript (`<audio>_transcript.json`).
struct TranscriptLine: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
}

enum TranscriptDocument {
    static func load(path: String) throws -> [TranscriptLine] {
        try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Index of the last line that started at or before `time` (lines are start-ordered).
    static func lineIndex(at time: Double, in lines: [TranscriptLine]) -> Int? {
        lines.lastIndex { $0.start <= time }
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// User names for the worker's speaker labels, kept in `<audio-base>_speakers.json`.
/// Keyed by the original label so Re-process (which regenerates labels) keeps them.
struct SpeakerNames: Codable, Equatable, Sendable {
    static let maxNameLength = 80
    private var names: [String: String] = [:]

    init() {}

    var isEmpty: Bool { names.isEmpty }

    func display(_ label: String?) -> String? {
        label.map { names[$0] ?? $0 }
    }

    /// A blank name removes the mapping.
    func renamed(_ label: String, to name: String) -> SpeakerNames {
        var copy = self
        let clean = String(name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(Self.maxNameLength))
        copy.names[label] = clean.isEmpty || clean == label ? nil : clean
        return copy
    }

    func applied(to lines: [TranscriptLine]) -> [TranscriptLine] {
        lines.map { TranscriptLine(start: $0.start, end: $0.end, text: $0.text, speaker: display($0.speaker)) }
    }

    /// Single pass, whole labels only. `Speaker …` labels are replaced anywhere; other
    /// labels (e.g. `You`) only where the note renders a speaker, so prose stays intact.
    func apply(to text: String) -> String {
        let labels = names.keys.sorted { $0.count > $1.count }
        let pattern = "(?<![\\p{L}\\p{N}])(?:"
            + labels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            + ")(?![\\p{L}\\p{N}])"
        guard !labels.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let label = source.substring(with: match.range)
            guard let name = names[label], Self.replaceable(label, at: match.range, in: source) else { continue }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + name
            cursor = NSMaxRange(match.range)
        }
        return output + source.substring(from: cursor)
    }

    private static func replaceable(_ label: String, at range: NSRange, in text: NSString) -> Bool {
        if label.hasPrefix("Speaker ") { return true }
        func before(_ n: Int) -> String {
            text.substring(with: NSRange(location: max(0, range.location - n), length: min(n, range.location)))
        }
        func after(_ n: Int) -> String {
            let start = NSMaxRange(range)
            return text.substring(with: NSRange(location: start, length: min(n, text.length - start)))
        }
        let lineStart = range.location == 4 || before(5).hasPrefix("\n")
        let lineEnd = NSMaxRange(range) == text.length || after(1) == "\n" || after(1) == "\r"
        return (before(2) == "**" && after(3) == ":**")
            || (before(2) == "| " && after(2) == " |")
            || (before(4) == "  - " && lineStart && lineEnd)
    }

    // MARK: Persistence

    static func sidecarPath(audioPath: String) -> String {
        (audioPath as NSString).deletingPathExtension + "_speakers.json"
    }

    static func load(audioPath: String) throws -> SpeakerNames {
        let path = sidecarPath(audioPath: audioPath)
        guard FileManager.default.fileExists(atPath: path) else { return SpeakerNames() }
        let raw = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        return raw.reduce(SpeakerNames()) { $0.renamed($1.key, to: $1.value) }
    }

    func save(audioPath: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(names).write(to: URL(fileURLWithPath: Self.sidecarPath(audioPath: audioPath)),
                                        options: .atomic)
        // Every rename (web, native window) goes through here, so open pages hear about it.
        ModelFileEvents.notify(.speakerNames(audioPath: audioPath))
    }

    init(from decoder: Decoder) throws {
        names = try decoder.singleValueContainer().decode([String: String].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(names)
    }
}
