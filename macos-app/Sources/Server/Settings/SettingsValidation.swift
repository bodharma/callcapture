import Foundation

/// Why a `PATCH /api/settings` body was refused. `key` is the dotted setting path
/// ("recording.outputDirectory") when the problem is about one setting. Messages never
/// repeat the submitted value.
struct SettingsInvalid: Error, Equatable, Sendable {
    let key: String?
    let message: String
}

/// Turns a raw PATCH body into a `SettingsPatch`, checking every key and value first,
/// so a body with any problem changes nothing. Shape: `{"<pane>": {"<setting>": value}}`,
/// the same grouping `GET /api/settings` uses.
enum SettingsValidation {
    static let maxBodyBytes = 16 * 1024

    static func patch(from data: Data) throws -> SettingsPatch {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let groups) = root else {
            throw SettingsInvalid(key: nil, message: "Send the settings to change as a JSON object, grouped by pane.")
        }
        var patch = SettingsPatch()
        for group in groups.keys.sorted() {
            if let reason = readOnly[group] { throw SettingsInvalid(key: group, message: reason) }
            guard let fields = fields[group] else {
                throw SettingsInvalid(key: group, message: "Unknown settings group \(group).")
            }
            guard case .object(let entries) = groups[group] else {
                throw SettingsInvalid(key: group, message: "\(group) must be an object of settings.")
            }
            for name in entries.keys.sorted() {
                let key = "\(group).\(name)"
                if let reason = readOnly[key] { throw SettingsInvalid(key: key, message: reason) }
                guard let parse = fields[name], let value = entries[name] else {
                    throw SettingsInvalid(key: key, message: "Unknown setting \(key).")
                }
                try parse(value, key, &patch)
            }
        }
        return patch
    }

    private typealias Parser = (JSONValue, String, inout SettingsPatch) throws -> Void

    private static let fields: [String: [String: Parser]] = [
        "general": ["autoProcessOnStop": flag(\.autoProcessOnStop)],
        "recording": [
            "outputDirectory": folder(\.outputDirectory, label: "output folder", writable: true),
            "keepSeparateMicTrack": flag(\.keepSeparateMicTrack),
        ],
        "transcription": [
            "engine": choice(\.engine),
            "whisperModel": choice(\.whisperModel),
            "remoteProvider": choice(\.remoteProvider),
        ],
        "aiNotes": [
            "provider": choice(\.provider),
            "finalModel": modelID(\.finalModel, label: "final notes model", allowEmpty: false),
            "liveModel": modelID(\.liveModel, label: "live notes model", allowEmpty: false),
            "localModel": modelID(\.localModel, label: "local model", allowEmpty: true),
            "localBaseURL": serverAddress(\.localBaseURL),
        ],
        "vault": [
            "obsidianVault": folder(\.obsidianVault, label: "Obsidian vault", writable: false),
            "folderPattern": folderPattern(\.folderPattern),
            "markdownProfile": choice(\.markdownProfile),
        ],
        "costs": [
            "assemblyAIPerMin": rate(\.assemblyAIPerMin, label: "AssemblyAI rate"),
            "deepgramPerMin": rate(\.deepgramPerMin, label: "Deepgram rate"),
            "openAIPerMin": rate(\.openAIPerMin, label: "OpenAI rate"),
            "groqPerMin": rate(\.groqPerMin, label: "Groq rate"),
            "llmFallbackPer1M": rate(\.llmFallbackPer1M, label: "fallback AI notes rate"),
        ],
    ]

    /// Reports in the snapshot that a client may read but not send back.
    private static let readOnly: [String: String] = [
        "transcription.models": "transcription.models can't be changed: it reports model downloads.",
        "aiNotes.warnings": "aiNotes.warnings can't be changed: the app works them out from the chosen models.",
        "offlineReasons": "offlineReasons can't be changed: it is the app's wording.",
        "secrets": "Keys can't be sent here. Save one with PUT /api/settings/secrets/<name>, remove it with DELETE.",
    ]

    static let maxRate = 1_000.0
    private static let maxTextLength = 500

    // MARK: Parsers

    private static func flag(_ path: WritableKeyPath<SettingsPatch, Bool?>) -> Parser {
        { value, key, patch in
            guard case .bool(let flag) = value else { throw SettingsInvalid(key: key, message: "\(key) must be true or false.") }
            patch[keyPath: path] = flag
        }
    }

    private static func choice<E: RawRepresentable & CaseIterable>(_ path: WritableKeyPath<SettingsPatch, E?>) -> Parser
    where E.RawValue == String {
        { value, key, patch in
            guard case .string(let raw) = value, let choice = E(rawValue: raw) else {
                let allowed = E.allCases.map(\.rawValue).joined(separator: ", ")
                throw SettingsInvalid(key: key, message: "\(key) must be one of: \(allowed).")
            }
            patch[keyPath: path] = choice
        }
    }

    private static func rate(_ path: WritableKeyPath<SettingsPatch, Double?>, label: String) -> Parser {
        { value, key, patch in
            guard case .number(let number) = value else { throw SettingsInvalid(key: key, message: "\(key) must be a number.") }
            guard number.isFinite, number >= 0, number <= maxRate else {
                throw SettingsInvalid(key: key, message: "The \(label) must be 0 or more, and at most 1000.")
            }
            patch[keyPath: path] = number
        }
    }

    private static func modelID(_ path: WritableKeyPath<SettingsPatch, String?>, label: String, allowEmpty: Bool) -> Parser {
        { value, key, patch in
            let id = try text(value, key).trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty, !allowEmpty { throw SettingsInvalid(key: key, message: "Choose a \(label); it can't be empty.") }
            guard id.count <= 200, !id.contains(where: \.isWhitespace), !hasControlCharacters(id) else {
                throw SettingsInvalid(
                    key: key, message: "The \(label) must be a model id without spaces, like google/gemini-2.5-flash.")
            }
            patch[keyPath: path] = id
        }
    }

    private static func serverAddress(_ path: WritableKeyPath<SettingsPatch, String?>) -> Parser {
        { value, key, patch in
            let address = try text(value, key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard address.count <= maxTextLength, let url = URL(string: address),
                let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                let host = url.host, !host.isEmpty
            else {
                throw SettingsInvalid(
                    key: key,
                    message: "The local model server must be an http:// or https:// address, like http://localhost:11434/v1.")
            }
            patch[keyPath: path] = address
        }
    }

    private static func folderPattern(_ path: WritableKeyPath<SettingsPatch, String?>) -> Parser {
        { value, key, patch in
            let pattern = try text(value, key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else {
                throw SettingsInvalid(key: key, message: "The vault folder pattern can't be empty. Try _meetings/{YYYY-MM}/.")
            }
            let parts = pattern.split(separator: "/")
            guard !pattern.hasPrefix("/"), !pattern.hasPrefix("~"), !parts.contains(".."),
                pattern.count <= maxTextLength, !hasControlCharacters(pattern)
            else {
                throw SettingsInvalid(
                    key: key,
                    message: "The vault folder pattern must stay inside the vault: a relative path without “..”, like _meetings/{YYYY-MM}/.")
            }
            patch[keyPath: path] = pattern
        }
    }

    private static func folder(_ path: WritableKeyPath<SettingsPatch, String?>, label: String, writable: Bool) -> Parser {
        { value, key, patch in
            patch[keyPath: path] = try checkedFolder(try text(value, key), key: key, label: label, writable: writable)
        }
    }

    /// An absolute, existing directory (writable when asked), with `~` expanded and
    /// `.`/`..`/trailing slashes removed.
    static func checkedFolder(_ raw: String, key: String, label: String, writable: Bool) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsInvalid(key: key, message: "Choose the \(label); it can't be empty.") }
        guard trimmed.count <= 4_096, !hasControlCharacters(trimmed) else {
            throw SettingsInvalid(key: key, message: "The \(label) path can't contain control characters.")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw SettingsInvalid(key: key, message: "The \(label) must be a full path that starts with / or ~.")
        }
        let folder = URL(fileURLWithPath: expanded).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) else {
            throw SettingsInvalid(key: key, message: "The \(label) doesn't exist. Choose an existing folder.")
        }
        guard isDirectory.boolValue else {
            throw SettingsInvalid(key: key, message: "The \(label) is a file, not a folder. Choose a folder.")
        }
        if writable, !FileManager.default.isWritableFile(atPath: folder) {
            throw SettingsInvalid(key: key, message: "CallCapture can't write to the \(label). Choose a folder you can write to.")
        }
        return folder
    }

    private static func text(_ value: JSONValue, _ key: String) throws -> String {
        guard case .string(let text) = value else { throw SettingsInvalid(key: key, message: "\(key) must be text.") }
        return text
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
