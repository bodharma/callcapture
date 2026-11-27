import Foundation
import Hummingbird
import os

/// Routes for the loopback HTTP server that backs the local web UI.
func makeRouter(
    backend: any AppBackend, security: ServerSecurity,
    webDirectory: URL? = defaultWebDirectory(), eventHeartbeat: Duration = .seconds(15)
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
    addSystemRoutes(to: router, backend: backend)
    addSessionsRoutes(to: router, backend: backend)
    addSettingsRoutes(to: router, backend: backend)
    addCatalogRoutes(to: router, backend: backend)
    addEventsRoute(to: router, backend: backend, heartbeat: eventHeartbeat)
    addRecordingRoutes(to: router, backend: backend)
    addLiveRoutes(to: router, backend: backend)
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

/// Loopback HTTP server. Binds `127.0.0.1` on the last run's port when it is free
/// (`ServerPortChoice`), else on an OS-chosen one, and owns the `ServerSecurity`
/// whose Host/Origin guard needs that port; the port is set once from the
/// server-running callback, which Hummingbird awaits before it accepts any connection.
final class LocalServer: Sendable {
    private let backend: any AppBackend
    let security = ServerSecurity(port: 0)
    private let runner = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    init(backend: any AppBackend) {
        self.backend = backend
    }

    /// Starts serving on `saved` if it can be bound, else on any free port; returns the bound port.
    func start(preferring saved: Int? = nil) async throws -> Int {
        try await ServerPortChoice.bind(preferring: saved) { port in try await run(port: port) }
    }

    /// One attempt on `port` (0: the OS chooses). A failed attempt has ended its server
    /// before this throws, so the next attempt starts with a fresh `Application`.
    private func run(port: Int) async throws -> Int {
        let (ports, portSink) = AsyncThrowingStream<Int, any Error>.makeStream()
        let security = self.security
        let app = Application(
            router: makeRouter(backend: backend, security: security),
            configuration: .init(address: .hostname("127.0.0.1", port: port)),
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
        do {
            for try await bound in ports { return bound }
            throw LocalServerError.stoppedBeforeRunning
        } catch {
            // A bind failure has already ended `runService`; anything else is stopped here.
            task.cancel()
            await task.value
            runner.withLock { current in
                if current == task { current = nil }
            }
            throw error
        }
    }

    func stop() async {
        let task = runner.withLock { current -> Task<Void, Never>? in
            defer { current = nil }
            return current
        }
        // Open event streams never end by themselves; end them so shutdown doesn't wait.
        await backend.events.finishAll()
        task?.cancel()
        await task?.value
    }

    func loginURL(path: String) -> URL {
        Self.makeLoginURL(port: security.port, token: security.issueLoginToken(), next: path)
    }

    /// Pure URL construction for the single-use login hand-off; `next` is
    /// percent-encoded by `URLComponents`.
    static func makeLoginURL(port: Int, token: String, next: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/login"
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "token", value: encodeQueryValue(token)),
            URLQueryItem(name: "next", value: encodeQueryValue(next)),
        ]
        return components.url!
    }

    /// Encodes everything but unreserved characters and `/`, so `+`, `&`, `?`,
    /// `=` and `#` in a value can never be misread as query syntax or a space.
    private static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

enum LocalServerError: Error {
    case noBoundPort
    case stoppedBeforeRunning
}
