import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

/// Mutable clock the tests can advance.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private let hostName = HTTPField.Name("Host")!
private let port = 54321
private let goodHost: HTTPFields = [hostName: "127.0.0.1:\(port)"]

private func makeApp(_ security: ServerSecurity) -> some ApplicationProtocol {
    Application(router: makeRouter(backend: FakeBackend(), security: security))
}

private func sessionCookie(_ security: ServerSecurity) -> HTTPFields {
    let id = security.exchange(token: security.issueLoginToken())!
    return [hostName: "127.0.0.1:\(port)", .cookie: "cc_session=\(id)"]
}

@Suite("Server security")
struct ServerSecurityTests {
    @Test("a foreign Host header is rejected")
    func rejectsForeignHost() async throws {
        let security = ServerSecurity(port: port)
        try await makeApp(security).test(.router) { client in
            for host in ["evil.example:\(port)", "127.0.0.1:1", "localhost"] {
                try await client.execute(
                    uri: "/api/health", method: .get, headers: [hostName: host]
                ) { #expect($0.status == .forbidden) }
            }
            try await client.execute(
                uri: "/api/health", method: .get, headers: [hostName: "localhost:\(port)"]
            ) { #expect($0.status == .unauthorized) }  // host passes, session missing
        }
    }

    @Test("cross-origin writes are rejected, same-origin ones pass the guard")
    func rejectsCrossOriginWrites() async throws {
        let security = ServerSecurity(port: port)
        let base = sessionCookie(security)
        var foreign = base
        foreign[.origin] = "https://evil.example"
        var same = base
        same[.origin] = "http://127.0.0.1:\(port)"
        let foreignHeaders = foreign
        let sameHeaders = same
        try await makeApp(security).test(.router) { client in
            try await client.execute(uri: "/api/anything", method: .post, headers: foreignHeaders) {
                #expect($0.status == .forbidden)
            }
            try await client.execute(uri: "/api/anything", method: .post, headers: sameHeaders) {
                #expect($0.status == .notFound)  // past the guard, no such route
            }
        }
    }

    @Test("/api requires a session and answers a JSON sign-in error")
    func requiresSession() async throws {
        let security = ServerSecurity(port: port)
        try await makeApp(security).test(.router) { client in
            try await client.execute(uri: "/api/health", method: .get, headers: goodHost) {
                #expect($0.status == .unauthorized)
                #expect($0.headers[.contentType]?.hasPrefix("application/json") == true)
                #expect(String(buffer: $0.body) == #"{"error":"signin"}"#)
            }
            try await client.execute(
                uri: "/api/health", method: .get,
                headers: [hostName: "127.0.0.1:\(port)", .cookie: "cc_session=forged"]
            ) { #expect($0.status == .unauthorized) }
            try await client.execute(
                uri: "/api/health", method: .get, headers: sessionCookie(security)
            ) { #expect($0.status == .ok) }
        }
    }

    @Test("login swaps a token for a cookie once, and only within 60 s")
    func loginExchangesTokenOnce() async throws {
        let clock = TestClock()
        let security = ServerSecurity(port: port, now: { clock.now() })
        try await makeApp(security).test(.router) { client in
            let token = security.issueLoginToken()
            try await client.execute(
                uri: "/login?token=\(token)&next=/sessions", method: .get, headers: goodHost
            ) {
                #expect($0.status == .found)
                #expect($0.headers[.location] == "/sessions")
                let cookie = $0.headers[values: .setCookie].first ?? ""
                #expect(cookie.hasPrefix("cc_session="))
                #expect(cookie.contains("HttpOnly"))
                #expect(cookie.contains("SameSite=Strict"))
                #expect(cookie.contains("Path=/"))
            }
            try await client.execute(
                uri: "/login?token=\(token)&next=/sessions", method: .get, headers: goodHost
            ) { #expect($0.status == .unauthorized) }

            let stale = security.issueLoginToken()
            clock.advance(61)
            try await client.execute(
                uri: "/login?token=\(stale)", method: .get, headers: goodHost
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("login only redirects to local paths", arguments: [
        "//evil.example", "https://evil.example/x", "evil", "/\\evil.example", "",
    ])
    func loginRejectsOpenRedirect(next: String) async throws {
        let security = ServerSecurity(port: port)
        let encoded = next.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        try await makeApp(security).test(.router) { client in
            try await client.execute(
                uri: "/login?token=\(security.issueLoginToken())&next=\(encoded)",
                method: .get, headers: goodHost
            ) { #expect($0.headers[.location] == "/") }
        }
    }

    @Test("sessions do not survive a new ServerSecurity")
    func sessionsDieWithTheServer() {
        let first = ServerSecurity(port: port)
        let session = first.exchange(token: first.issueLoginToken())
        #expect(session != nil)
        #expect(first.isValidSession(session!))
        #expect(!ServerSecurity(port: port).isValidSession(session!))
    }

    @Test("tokens are 32 random bytes, base64url")
    func tokenShape() {
        let token = ServerSecurity.randomToken()
        #expect(token.count == 43)
        #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(token != ServerSecurity.randomToken())
    }
}
