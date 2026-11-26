import Foundation

/// Single-range `Range` header handling (RFC 9110 §14).
///
/// Only one byte range is honoured. A multi-range or malformed header is
/// ignored (the full body is served with 200), as the RFC allows.
enum HTTPRange: Equatable, Sendable {
    /// No usable Range header: serve the whole body with 200.
    case full
    /// Serve these byte offsets (inclusive) with 206.
    case partial(ClosedRange<Int>)
    /// 416 with `Content-Range: bytes */<size>`.
    case unsatisfiable

    static func parse(_ header: String?, size: Int) -> HTTPRange {
        guard let header, let spec = singleSpec(header) else { return .full }
        let parts = spec.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }
        let (lhs, rhs) = (parts[0], parts[1])

        if lhs.isEmpty {  // suffix: the last n bytes
            guard let length = number(rhs) else { return .full }
            guard length > 0, size > 0 else { return .unsatisfiable }
            return .partial(max(0, size - length)...(size - 1))
        }
        guard let first = number(lhs) else { return .full }
        var last = size - 1
        if !rhs.isEmpty {
            guard let end = number(rhs), end >= first else { return .full }
            last = min(end, size - 1)
        }
        guard first < size else { return .unsatisfiable }
        return .partial(first...last)
    }

    static func contentRange(_ range: ClosedRange<Int>, size: Int) -> String {
        "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
    }

    static func unsatisfiedRange(size: Int) -> String { "bytes */\(size)" }

    /// The one range-spec after `bytes=`, or nil for another unit, a list or no `=`.
    private static func singleSpec(_ header: String) -> Substring? {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard let equals = value.firstIndex(of: "="),
            value[..<equals].lowercased() == "bytes"
        else { return nil }
        let set = value[value.index(after: equals)...]
        guard !set.contains(",") else { return nil }
        return Substring(set.trimmingCharacters(in: .whitespaces))
    }

    /// ASCII digits only. Saturates instead of trapping: an absurd offset is still
    /// "past the end" and an absurd length still "the whole file".
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        var value = 0
        for byte in text.utf8 {
            let (shifted, overflowA) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflowB) = shifted.addingReportingOverflow(Int(byte - 0x30))
            if overflowA || overflowB { return Int.max }
            value = sum
        }
        return value
    }
}
