import Foundation
import Testing

@testable import CallCapture

@Suite("Web host navigation decision")
struct NavigationDecisionTests {
    private let port = 51234

    private func decide(_ string: String?, port: Int? = 51234) -> NavigationDecision {
        NavigationDecision.decide(url: string.flatMap(URL.init(string:)), ownPort: port)
    }

    @Test("own loopback origin is allowed")
    func ownOrigin() {
        #expect(decide("http://127.0.0.1:51234/sessions") == .allow)
        #expect(decide("http://localhost:51234/live?compact=1") == .allow)
        #expect(decide("about:blank") == .allow)
    }

    @Test("lookalike origins are not allowed in the web view")
    func lookalikes() {
        for url in [
            "http://127.0.0.1:51235/", "https://127.0.0.1:51234/",
            "http://example.com:51234/", "http://127.0.0.1:51234@evil.example/",
            "http://127.0.0.1.evil.example:51234/", "http://user:pw@127.0.0.1:51234/",
        ] {
            #expect(decide(url) != .allow, "\(url)")
        }
        #expect(decide("http://127.0.0.1:51234/", port: nil) != .allow)
    }

    @Test("only http(s) opens externally")
    func externalWeb() {
        #expect(decide("https://example.com") == .openExternally)
        #expect(decide("http://example.com") == .openExternally)
    }

    @Test("every other scheme is cancelled")
    func cancelled() {
        for url in [
            "file:///Applications/Calculator.app", "data:text/html,x",
            "blob:http://127.0.0.1:51234/uuid", "x-apple.systempreferences:",
            "tel:123", "mailto:a@b.c", "about:config",
        ] {
            #expect(decide(url) == .cancel, "\(url)")
        }
        #expect(decide(nil) == .cancel)
    }
}
