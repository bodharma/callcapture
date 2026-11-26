import Foundation
import Testing

@testable import CallCapture

@Suite("Login URL")
struct LoginURLTests {
    @Test("loginURLShape: loopback host, bound port, /login, token and next")
    func loginURLShape() throws {
        let url = LocalServer.makeLoginURL(port: 51234, token: "tok123", next: "/sessions")
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 51234)
        #expect(url.path == "/login")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "token" }?.value == "tok123")
        #expect(items.first { $0.name == "next" }?.value == "/sessions")
    }

    @Test("next round-trips through URLComponents for awkward paths")
    func nextRoundTrips() throws {
        for next in ["/sessions?q=a&b=c d", "/live?compact=1", "/s/é ü/日本語?x=1&y=#frag", "/a b/c", "/s?q=1+2"] {
            let url = LocalServer.makeLoginURL(port: 1, token: "t", next: next)
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(items.first { $0.name == "next" }?.value == next)
            #expect(items.count == 2)
            #expect(!url.absoluteString.contains("+"))
        }
    }

    @Test("each issued login token is fresh")
    func tokensDiffer() {
        let security = ServerSecurity(port: 1)
        #expect(security.issueLoginToken() != security.issueLoginToken())
    }
}
