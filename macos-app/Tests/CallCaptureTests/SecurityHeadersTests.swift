import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

/// `X-Content-Type-Options: nosniff` on every response, including the guard's 401/403
/// and errors Hummingbird builds after a throw; HTML pages also refuse to be framed.
@Suite struct SecurityHeadersTests {
    private static let port = 54_323
    private static let authority = "127.0.0.1:\(port)"

    private let web = FileManager.default.temporaryDirectory.appendingPathComponent("cc-headers-\(UUID().uuidString)")

    private func makeWeb() throws {
        try FileManager.default.createDirectory(at: web.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "<html>INDEX</html>".write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "export {}".write(to: web.appendingPathComponent("assets/app.js"), atomically: true, encoding: .utf8)
    }

    private func expectNoSniff(_ response: TestResponse, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(response.headers[.xContentTypeOptions] == "nosniff", "\(response.status)", sourceLocation: sourceLocation)
    }

    @Test func htmlPagesRefuseToBeFramed() async throws {
        try makeWeb()
        defer { try? FileManager.default.removeItem(at: web) }
        let app = makeServerApp(ServerSecurity(port: Self.port), authority: Self.authority, webDirectory: web)
        try await app.test(.router) { client in
            for path in ["/", "/sessions/S1"] {
                let page = try await client.execute(uri: path, method: .get)
                #expect(page.status == .ok)
                #expect(page.headers[.contentSecurityPolicy] == "frame-ancestors 'none'", "\(path)")
                #expect(page.headers[HTTPField.Name("X-Frame-Options")!] == "DENY", "\(path)")
                expectNoSniff(page)
            }
            let script = try await client.execute(uri: "/assets/app.js", method: .get)
            #expect(script.status == .ok)
            expectNoSniff(script)
        }
    }

    @Test func apiAnswersAndRefusalsAreNotSniffed() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let list = try await api.request(client, "/api/sessions")
            #expect(list.status == .ok)
            expectNoSniff(list)
            let unsigned = try await client.execute(uri: "/api/sessions", method: .get)
            #expect(unsigned.status == .unauthorized)
            expectNoSniff(unsigned)
        }
    }

    @Test func aForeignHostRefusalIsNotSniffed() async throws {
        let app = makeServerApp(ServerSecurity(port: Self.port), authority: "evil.example:\(Self.port)")
        try await app.test(.router) { client in
            let refused = try await client.execute(uri: "/api/health", method: .get)
            #expect(refused.status == .forbidden)
            expectNoSniff(refused)
        }
    }

    /// No route matches: Hummingbird's not-found responder throws, and the error becomes the answer.
    @Test func anErrorBuiltAfterAThrowIsNotSniffed() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let missing = try await api.request(client, "/api/nothing-here", method: .post)
            #expect(missing.status == .notFound)
            expectNoSniff(missing)
        }
    }
}
