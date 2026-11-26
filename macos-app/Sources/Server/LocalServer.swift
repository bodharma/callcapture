import Foundation
import Hummingbird
import NIOCore

/// Routes for the loopback HTTP server that backs the local web UI.
func makeRouter() -> Router<BasicRequestContext> {
    let router = Router()
    router.get("api/health") { _, _ in
        Response(
            status: .ok,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(string: #"{"ok":true}"#))
        )
    }
    return router
}
