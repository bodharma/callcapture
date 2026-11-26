import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

private let port = 54321
private let authority = "127.0.0.1:\(port)"

/// Builds a throwaway web directory: index.html, assets/app.js, and a secret
/// file one level above it that must never be served.
private struct WebFixture {
    let root: URL
    let web: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-web-\(UUID().uuidString)")
        web = root.appendingPathComponent("web")
        let fm = FileManager.default
        try fm.createDirectory(
            at: web.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "<html>INDEX</html>".write(
            to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log(1)".write(
            to: web.appendingPathComponent("assets/app.js"), atomically: true, encoding: .utf8)
        try "TOP-SECRET".write(
            to: root.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func makeApp(webDirectory: URL?) -> some ApplicationProtocol {
    let security = ServerSecurity(port: port)
    return makeServerApp(security, authority: authority, webDirectory: webDirectory)
}

@Suite("Static files")
struct StaticFilesTests {
    @Test("staticFallback: an SPA route returns index.html")
    func staticFallback() async throws {
        let fixture = try WebFixture()
        defer { fixture.cleanup() }
        try await makeApp(webDirectory: fixture.web).test(.router) { client in
            try await client.execute(uri: "/sessions/abc", method: .get) {
                #expect($0.status == .ok)
                #expect(String(buffer: $0.body).contains("INDEX"))
            }
            try await client.execute(uri: "/", method: .get) {
                #expect(String(buffer: $0.body).contains("INDEX"))
            }
        }
    }

    @Test("an existing asset is served with its content type")
    func servesAsset() async throws {
        let fixture = try WebFixture()
        defer { fixture.cleanup() }
        try await makeApp(webDirectory: fixture.web).test(.router) { client in
            try await client.execute(uri: "/assets/app.js", method: .get) {
                #expect($0.status == .ok)
                #expect(String(buffer: $0.body) == "console.log(1)")
                #expect($0.headers[.contentType]?.contains("javascript") == true)
            }
        }
    }

    @Test("unknown /api paths are 404 JSON, never index.html")
    func apiNotFound() async throws {
        let fixture = try WebFixture()
        defer { fixture.cleanup() }
        let security = ServerSecurity(port: port)
        let cookie = security.exchange(token: security.issueLoginToken())!
        try await makeServerApp(security, authority: authority, webDirectory: fixture.web)
            .test(.router) { client in
                try await client.execute(
                    uri: "/api/nope", method: .get, headers: [.cookie: "cc_session=\(cookie)"]
                ) {
                    #expect($0.status == .notFound)
                    #expect($0.headers[.contentType]?.contains("application/json") == true)
                    #expect(!String(buffer: $0.body).contains("INDEX"))
                }
            }
    }

    @Test("/login still wins over the SPA fallback")
    func loginStillRoutes() async throws {
        let fixture = try WebFixture()
        defer { fixture.cleanup() }
        try await makeApp(webDirectory: fixture.web).test(.router) { client in
            try await client.execute(uri: "/login?token=bogus", method: .get) {
                #expect(!String(buffer: $0.body).contains("INDEX"))
            }
        }
    }

    @Test("path traversal never reads outside the web directory",
          arguments: [
            "/../secret.txt", "/%2e%2e/secret.txt", "/%2E%2E/secret.txt",
            "/assets/../../secret.txt", "/assets/%2e%2e/%2e%2e/secret.txt",
            "/..%2fsecret.txt", "/assets/..%5c..%5csecret.txt",
          ])
    func traversal(path: String) async throws {
        let fixture = try WebFixture()
        defer { fixture.cleanup() }
        try await makeApp(webDirectory: fixture.web).test(.router) { client in
            try await client.execute(uri: path, method: .get) {
                #expect(!String(buffer: $0.body).contains("TOP-SECRET"))
            }
        }
    }

    @Test("a missing web directory answers 503 plain text")
    func missingDirectory() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-missing-\(UUID().uuidString)")
        try await makeApp(webDirectory: missing).test(.router) { client in
            try await client.execute(uri: "/sessions", method: .get) {
                #expect($0.status == .serviceUnavailable)
                #expect($0.headers[.contentType]?.contains("text/plain") == true)
                #expect(String(buffer: $0.body) == "Web UI not built")
            }
        }
    }
}
