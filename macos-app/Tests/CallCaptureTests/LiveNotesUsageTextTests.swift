import Testing

@testable import CallCapture

@Suite("Live notes usage line")
struct LiveNotesUsageTextTests {
    @Test("priced requests show the reported cost and the count")
    func priced() {
        let usage = LiveNotesUsage(requests: 61, reportedCostUSD: 0.04)
        #expect(LiveNotesUsageText.line(usage) == "Live notes so far: ≈ $0.04 · 61 requests")
    }

    @Test("one request is singular")
    func singular() {
        let usage = LiveNotesUsage(requests: 1, reportedCostUSD: 0.004)
        #expect(LiveNotesUsageText.line(usage) == "Live notes so far: ≈ $0.0040 · 1 request")
    }

    @Test("some requests without a reported cost are counted separately")
    func partlyUnpriced() {
        let usage = LiveNotesUsage(requests: 5, reportedCostUSD: 1.5, unpricedRequests: 2)
        #expect(LiveNotesUsageText.line(usage) == "Live notes so far: ≈ $1.50 · 5 requests (2 without reported cost)")
    }

    @Test("no reported cost at all says so instead of $0")
    func allUnpriced() {
        let usage = LiveNotesUsage(requests: 3, unpricedRequests: 3)
        #expect(LiveNotesUsageText.line(usage) == "Live notes: 3 requests, cost not reported")
    }

    @Test("a free model reads free")
    func free() {
        let usage = LiveNotesUsage(requests: 2, reportedCostUSD: 0)
        #expect(LiveNotesUsageText.line(usage) == "Live notes so far: ≈ free · 2 requests")
    }
}
