import Foundation

/// USD cost formatting for the cost UI. 4 decimals (sub-cent calls are common).
enum CostFormat {
    static func usd(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.4f", value)
    }

    /// Sum of the two parts, or nil if both are nil.
    static func total(_ a: Double?, _ b: Double?) -> Double? {
        if a == nil && b == nil { return nil }
        return (a ?? 0) + (b ?? 0)
    }
}
