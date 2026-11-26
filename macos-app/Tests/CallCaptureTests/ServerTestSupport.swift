import Foundation
import HTTPTypes
import Hummingbird

@testable import CallCapture

/// The `.router` harness hard-codes the request authority to "localhost"
/// (no port), which the Host guard rightly rejects. This wraps the real
/// router and stamps the authority a live connection would carry (NIO turns
/// the Host header into the authority), so tests exercise the production
/// branch, including a missing authority.
func makeServerApp(
    _ security: ServerSecurity, authority: String?, webDirectory: URL? = nil
) -> some ApplicationProtocol {
    let router = makeRouter(
        backend: FakeBackend(), security: security, webDirectory: webDirectory).buildResponder()
    return Application(
        responder: CallbackResponder<BasicRequestContext> { request, context in
            var head = request.head
            head.authority = authority
            let stamped = Request(head: head, body: request.body)
            return try await router.respond(to: stamped, context: context)
        })
}
