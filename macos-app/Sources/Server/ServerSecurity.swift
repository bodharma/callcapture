import Foundation
import HTTPTypes
import Hummingbird
import os
import Security

/// Session and login-token state for the loopback server, plus the port the
/// Host/Origin guard compares against.
///
/// Everything is in memory on purpose: sessions die with the process.
final class ServerSecurity: Sendable {
    static let sessionCookieName = "cc_session"
    static let tokenTimeToLive: TimeInterval = 60

    private struct State {
        var port: Int
        var tokens: [String: Date] = [:]  // token -> expiry
        var sessions: Set<String> = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let now: @Sendable () -> Date

    /// - Parameter port: The port the server listens on; `0` until it is
    ///   bound, then set once with `bind(port:)`.
    init(port: Int, now: @escaping @Sendable () -> Date = { Date() }) {
        self.state = OSAllocatedUnfairLock(initialState: State(port: port))
        self.now = now
    }

    var port: Int { state.withLock { $0.port } }

    func bind(port: Int) {
        state.withLock { $0.port = port }
    }

    /// Creates a single-use login token valid for 60 seconds.
    func issueLoginToken() -> String {
        let token = Self.randomToken()
        let expiry = now().addingTimeInterval(Self.tokenTimeToLive)
        state.withLock { $0.tokens[token] = expiry }
        return token
    }

    /// Swaps a login token for a session id. The token is consumed whether or
    /// not it is still fresh.
    func exchange(token: String) -> String? {
        let current = now()
        let session = Self.randomToken()
        return state.withLock { state -> String? in
            // Compare against every stored token without early exit so timing
            // does not reveal which prefix matched.
            var matched: String?
            for (stored, expiry) in state.tokens
            where Self.constantTimeEquals(stored, token) {
                matched = expiry > current ? stored : nil
                state.tokens[stored] = nil
            }
            state.tokens = state.tokens.filter { $0.value > current }
            guard matched != nil else { return nil }
            state.sessions.insert(session)
            return session
        }
    }

    func isValidSession(_ id: String) -> Bool {
        state.withLock { state in
            var found = false
            for stored in state.sessions where Self.constantTimeEquals(stored, id) {
                found = true
            }
            return found
        }
    }

    // MARK: Host / Origin

    func isAllowedHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let port = self.port
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    func isAllowedOrigin(_ origin: String) -> Bool {
        let port = self.port
        return origin == "http://127.0.0.1:\(port)" || origin == "http://localhost:\(port)"
    }

    // MARK: Helpers

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        var diff = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
        for index in 0..<max(lhs.count, rhs.count) {
            let x = index < lhs.count ? lhs[index] : 0
            let y = index < rhs.count ? rhs[index] : 0
            diff |= x ^ y
        }
        return diff == 0
    }
}

private let signinBody = #"{"error":"signin"}"#

private func jsonResponse(_ status: HTTPResponse.Status, _ body: String) -> Response {
    Response(
        status: status,
        headers: [.contentType: "application/json; charset=utf-8"],
        body: .init(byteBuffer: .init(string: body))
    )
}

func signinRequiredResponse() -> Response { jsonResponse(.unauthorized, signinBody) }

/// Rejects requests whose Host is not this loopback address (DNS rebinding)
/// and state-changing requests carrying a foreign Origin (cross-site writes).
struct LoopbackGuardMiddleware<Context: RequestContext>: RouterMiddleware {
    let security: ServerSecurity
    static var hostField: HTTPField.Name { HTTPField.Name("Host")! }

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // On a real connection NIO moves the HTTP/1 Host into the request
        // authority. HTTPTypes hides `Host` behind `.host` (unavailable), so
        // a literal Host field is read by name; it takes precedence, which
        // is what lets router-level tests choose the host.
        let host = request.headers[Self.hostField] ?? request.head.authority
        guard security.isAllowedHost(host) else {
            return jsonResponse(.forbidden, #"{"error":"forbidden host"}"#)
        }
        let writes: Set<HTTPRequest.Method> = [.post, .put, .patch, .delete]
        if writes.contains(request.method),
            let origin = request.headers[.origin],
            !security.isAllowedOrigin(origin)
        {
            return jsonResponse(.forbidden, #"{"error":"forbidden origin"}"#)
        }
        return try await next(request, context)
    }
}

/// Requires a valid `cc_session` cookie on every `/api/*` path.
struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let security: ServerSecurity

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let path = request.uri.path
        if path == "/api" || path.hasPrefix("/api/") {
            guard let session = request.cookies[ServerSecurity.sessionCookieName]?.value,
                security.isValidSession(session)
            else { return signinRequiredResponse() }
        }
        return try await next(request, context)
    }
}
