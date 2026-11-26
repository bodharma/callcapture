import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import CallCapture

@Suite("Local server health")
struct ServerHealthTests {
    @Test("GET /api/health answers {\"ok\":true} as JSON")
    func healthAnswers() async throws {
        let app = Application(router: makeRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/health", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.hasPrefix("application/json") == true)
                #expect(String(buffer: response.body) == #"{"ok":true}"#)
            }
        }
    }
}
