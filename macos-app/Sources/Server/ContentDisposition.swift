import Foundation

/// `Content-Disposition: attachment` values for downloads named after a session title.
///
/// The header value is always plain ASCII: `filename` carries an ASCII fallback,
/// and non-ASCII titles add `filename*` (RFC 6266 / RFC 8187) with the UTF-8 name
/// percent-encoded.
enum ContentDisposition {
    static let maxStemLength = 100
    static let emptyStem = "session"

    /// Separators, quotes and other characters file systems reject (same set the
    /// SwiftUI export used) become "-".
    private static let replaced = CharacterSet(charactersIn: "/\\:*?\"<>|%")
    /// RFC 8187 `attr-char`: everything else is percent-encoded.
    private static let attrChars = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)

    static func attachment(title: String, fileExtension: String) -> String {
        let stem = sanitizedStem(title)
        guard !stem.unicodeScalars.allSatisfy(\.isASCII) else {
            return "attachment; filename=\"\(stem).\(fileExtension)\""
        }
        let fallback = asciiFallback(stem)
        let encoded = percentEncoded("\(stem).\(fileExtension)")
        return "attachment; filename=\"\(fallback).\(fileExtension)\"; filename*=UTF-8''\(encoded)"
    }

    /// Drops control and format characters (CR/LF included), replaces rejected
    /// punctuation with "-", trims, and caps the length.
    static func sanitizedStem(_ title: String) -> String {
        let cleaned = title.unicodeScalars.compactMap { scalar -> String? in
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            return replaced.contains(scalar) ? "-" : String(scalar)
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(cleaned.prefix(maxStemLength)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? emptyStem : capped
    }

    /// Transliterated to Latin without diacritics, then any remaining non-ASCII
    /// removed; falls back to "session" when nothing readable is left.
    private static func asciiFallback(_ stem: String) -> String {
        let latin = stem.applyingTransform(.toLatin, reverse: false) ?? stem
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        let ascii = plain.unicodeScalars.compactMap { scalar -> String? in
            guard scalar.isASCII, scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
            return replaced.contains(scalar) ? "-" : String(scalar)
        }
        .joined()
        .trimmingCharacters(in: .whitespaces)
        return ascii.contains(where: { $0.isLetter || $0.isNumber }) ? ascii : emptyStem
    }

    private static func percentEncoded(_ value: String) -> String {
        value.utf8.map { byte in
            attrChars.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }
        .joined()
    }
}
