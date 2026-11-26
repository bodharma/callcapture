import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Testing

@testable import CallCapture

@Suite("Local server health")
struct ServerHealthTests {
    @Test("GET /api/health answers {\"ok\":true} as JSON")
    func healthAnswers() async throws {
        let security = ServerSecurity(port: 8080)
        let session = security.exchange(token: security.issueLoginToken())!
        let app = makeServerApp(security, authority: "127.0.0.1:8080")
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/health", method: .get,
                headers: [.cookie: "cc_session=\(session)"]
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.hasPrefix("application/json") == true)
                #expect(String(buffer: response.body) == #"{"ok":true}"#)
            }
        }
    }
}
