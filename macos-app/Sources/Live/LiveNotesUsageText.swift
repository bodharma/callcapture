import Foundation

/// The live-notes spend line, worded as the live workspace showed it (the web's
/// `liveFormat.usageLine` mirrors it).
enum LiveNotesUsageText {
    static func line(_ usage: LiveNotesUsage) -> String {
        let requests = "\(usage.requests) request\(usage.requests == 1 ? "" : "s")"
        if usage.unpricedRequests == usage.requests { return "Live notes: \(requests), cost not reported" }
        let unpriced = usage.unpricedRequests > 0 ? " (\(usage.unpricedRequests) without reported cost)" : ""
        return "Live notes so far: ≈ \(usd(usage.reportedCostUSD)) · \(requests)\(unpriced)"
    }

    /// "free", sub-cent amounts to 4 decimals, then cents, then whole dollars.
    static func usd(_ value: Double) -> String {
        switch value {
        case 0: "free"
        case ..<0.01: String(format: "$%.4f", value)
        case ..<10: String(format: "$%.2f", value)
        default: String(format: "$%.0f", value)
        }
    }
}
