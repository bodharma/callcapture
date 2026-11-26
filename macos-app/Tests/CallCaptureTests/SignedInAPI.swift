import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

/// A signed-in client for the in-process router (no sockets), over a `FakeBackend`.
struct SignedInAPI: Sendable {
    static let port = 54322
    static let authority = "127.0.0.1:\(port)"

    let backend: FakeBackend
    let security: ServerSecurity
    let cookie: String

    init(backend: FakeBackend = FakeBackend()) {
        let security = ServerSecurity(port: Self.port)
        self.backend = backend
        self.security = security
        self.cookie = "cc_session=" + security.exchange(token: security.issueLoginToken())!
    }

    var settings: FakeSettings { backend.settings }

    func run(_ test: @escaping @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        try await makeServerApp(security, authority: Self.authority, backend: backend).test(.router, test)
    }

    func request(
        _ client: any TestClientProtocol, _ path: String, method: HTTPRequest.Method = .get, json: String? = nil
    ) async throws -> TestResponse {
        var headers: HTTPFields = [.cookie: cookie]
        if json != nil { headers[.contentType] = "application/json" }
        return try await client.execute(
            uri: path, method: method, headers: headers, body: json.map { ByteBuffer(string: $0) })
    }
}

func bodyText(_ response: TestResponse) -> String { String(buffer: response.body) }

func jsonObject(_ response: TestResponse) throws -> [String: Any] {
    try #require(
        try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any],
        "not a JSON object: \(bodyText(response))")
}

/// `value` at a dotted path such as "secrets.openrouter.set".
func jsonValue(_ object: [String: Any], _ path: String) -> Any? {
    var current: Any? = object
    for part in path.split(separator: ".") {
        current = (current as? [String: Any])?[String(part)]
    }
    return current
}

/// 400 `{"error":"invalid", ...}` whose message mentions `mentioning` and, when given,
/// whose `key` names the setting.
func expectInvalid(
    _ response: TestResponse, mentioning: String, key: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(response.status == .badRequest, "\(bodyText(response))", sourceLocation: sourceLocation)
    let body = try jsonObject(response)
    #expect(body["error"] as? String == "invalid", sourceLocation: sourceLocation)
    let message = body["message"] as? String ?? ""
    #expect(message.contains(mentioning), "message: \(message)", sourceLocation: sourceLocation)
    if let key { #expect(body["key"] as? String == key, sourceLocation: sourceLocation) }
}
