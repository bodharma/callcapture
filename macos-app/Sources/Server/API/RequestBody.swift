import Foundation
import Hummingbird

/// Small JSON request bodies for `/api/*` routes.
enum RequestBody {
    static let defaultLimit = 16 * 1024

    /// The raw body; throws when it is larger than `limit`.
    static func data(_ request: Request, limit: Int = defaultLimit) async throws -> Data {
        let buffer = try await request.body.collect(upTo: limit)
        return Data(buffer.readableBytesView)
    }

    static func decode<T: Decodable>(_ type: T.Type, from request: Request, limit: Int = defaultLimit) async throws -> T {
        try JSONDecoder().decode(type, from: try await data(request, limit: limit))
    }
}

/// Runs a handler and maps anything it throws to a JSON error (see `APIResponse.from`).
func apiResult(_ handle: () async throws -> Response) async -> Response {
    do {
        return try await handle()
    } catch {
        return APIResponse.from(error)
    }
}
