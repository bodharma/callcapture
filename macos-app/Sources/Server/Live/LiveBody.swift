import Foundation

/// The JSON body of a live action, read field by field so a 400 can name the field.
/// A missing or non-object body reads as having no fields.
struct LiveBody {
    static let maxNote = 2_000
    static let maxTitle = 200
    static let maxID = 128

    struct Invalid: Error {
        let key: String
        let message: String
    }

    private let fields: [String: Any]

    init(_ data: Data) {
        fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// A non-blank string of at most `max` characters, kept as typed.
    func text(_ key: String, max: Int) throws -> String {
        guard let value = fields[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Invalid(key: key, message: "\(key) can't be empty.") }
        guard value.count <= max else { throw Invalid(key: key, message: "\(key) can be at most \(max) characters.") }
        return value
    }

    func kind(_ key: String) throws -> LiveMemoKind {
        guard let raw = fields[key] as? String, let kind = LiveMemoKind(rawValue: raw) else {
            let allowed = LiveMemoKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw Invalid(key: key, message: "\(key) must be one of: \(allowed).")
        }
        return kind
    }

    /// A topic id.
    func id(_ key: String) throws -> String {
        guard let value = fields[key] as? String, !value.isEmpty, value.count <= Self.maxID else {
            throw Invalid(key: key, message: "\(key) must be a topic id.")
        }
        return value
    }

    /// A topic id or null. With `required`, the key must be present (null means "top level").
    func optionalID(_ key: String, required: Bool = false) throws -> String? {
        guard let value = fields[key], !(value is NSNull) else {
            if required && fields[key] == nil {
                throw Invalid(key: key, message: "\(key) must be a topic id, or null for the top level.")
            }
            return nil
        }
        return try id(key)
    }

    func bool(_ key: String) throws -> Bool {
        // JSONSerialization reads `1` as a Bool-compatible NSNumber; accept only true/false.
        guard let number = fields[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw Invalid(key: key, message: "\(key) must be true or false.")
        }
        return number.boolValue
    }

    /// A two- or three-letter language code such as "uk".
    func languageCode(_ key: String) throws -> String {
        guard let value = fields[key] as? String, (2...3).contains(value.count),
            value.allSatisfy({ $0.isASCII && $0.isLowercase })
        else { throw Invalid(key: key, message: "\(key) must be a language code such as en or uk.") }
        return value
    }
}
