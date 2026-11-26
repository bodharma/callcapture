import Foundation
import Hummingbird
import os

/// Routes for the loopback HTTP server that backs the local web UI.
func makeRouter(
    backend: any AppBackend, security: ServerSecurity,
    webDirectory: URL? = defaultWebDirectory()
) -> Router<BasicRequestContext> {
    let router = Router<BasicRequestContext>()
    router.add(middleware: LoopbackGuardMiddleware(security: security))
    router.add(middleware: AuthMiddleware(security: security))

    router.get("login") { request, _ in
        guard let token = request.uri.queryParameters["token"].map(String.init),
            let session = security.exchange(token: token)
        else { return signinRequiredResponse() }
        let next = request.uri.queryParameters["next"].map(String.init)
        var response = Response(
            status: .found,
            headers: [.location: safeLocalPath(next)]
        )
        response.setCookie(
            Cookie(
                name: ServerSecurity.sessionCookieName, value: session,
                path: "/", httpOnly: true, sameSite: .strict))
        return response
    }

    router.get("api/health") { _, _ in
        Response(
            status: .ok,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: .init(string: #"{"ok":true}"#))
        )
    }
    addStaticRoutes(to: router, webDirectory: webDirectory)
    return router
}

/// Only same-origin absolute paths may be redirect targets; anything else
/// (scheme, `//host`, backslash tricks, control characters) falls back to `/`.
func safeLocalPath(_ candidate: String?) -> String {
    guard let candidate, candidate.hasPrefix("/"), !candidate.hasPrefix("//"),
        !candidate.contains("\\"),
        !candidate.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    else { return "/" }
    return candidate
}

/// Loopback HTTP server. Binds `127.0.0.1` on an OS-chosen port and owns the
/// `ServerSecurity` whose Host/Origin guard needs that port; the port is set
/// once from the server-running callback, which Hummingbird awaits before it
/// accepts any connection.
final class LocalServer: Sendable {
    private let backend: any AppBackend
    let security = ServerSecurity(port: 0)
    private let runner = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    init(backend: any AppBackend) {
        self.backend = backend
    }

    /// Starts serving and returns the bound port.
    func start() async throws -> Int {
        let (ports, portSink) = AsyncThrowingStream<Int, any Error>.makeStream()
        let security = self.security
        let app = Application(
            router: makeRouter(backend: backend, security: security),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in
                guard let port = channel.localAddress?.port else {
                    portSink.finish(throwing: LocalServerError.noBoundPort)
                    return
                }
                security.bind(port: port)
                portSink.yield(port)
                portSink.finish()
            }
        )
        let task = Task {
            do {
                // No signal handlers: AppDelegate owns SIGTERM/SIGINT.
                try await app.runService(gracefulShutdownSignals: [])
                portSink.finish(throwing: LocalServerError.stoppedBeforeRunning)
            } catch {
                portSink.finish(throwing: error)
            }
        }
        runner.withLock { $0 = task }
        for try await port in ports { return port }
        throw LocalServerError.stoppedBeforeRunning
    }

    func stop() async {
        let task = runner.withLock { current -> Task<Void, Never>? in
            defer { current = nil }
            return current
        }
        task?.cancel()
        await task?.value
    }

    func loginURL(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = security.port
        components.path = "/login"
        components.queryItems = [
            URLQueryItem(name: "token", value: security.issueLoginToken()),
            URLQueryItem(name: "next", value: path),
        ]
        return components.url!
    }
}

enum LocalServerError: Error {
    case noBoundPort
    case stoppedBeforeRunning
}
