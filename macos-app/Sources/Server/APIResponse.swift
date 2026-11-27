import Foundation
import HTTPTypes
import Hummingbird
import os

/// JSON bodies and error envelopes for `/api/*` routes. Errors are always
/// `{"error": "<code>"}`, plus `"message"` when there is something to tell the user.
enum APIResponse {
    private static let logger = Logger(subsystem: "com.callcapture.app", category: "API")

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
        do {
            return body(try makeEncoder().encode(value), status: status)
        } catch {
            logger.error("Response encoding failed: \(error.localizedDescription)")
            return self.error(.internalServerError, "failed")
        }
    }

    /// `key` names the setting a 400 `invalid` answer is about, so a form can show it under that field.
    static func error(
        _ status: HTTPResponse.Status, _ code: String, message: String? = nil, key: String? = nil
    ) -> Response {
        struct Envelope: Encodable {
            let error: String
            let message: String?
            let key: String?
        }
        let data = (try? makeEncoder().encode(Envelope(error: code, message: message, key: key)))
            ?? Data(#"{"error":"failed"}"#.utf8)
        return body(data, status: status)
    }

    static func notFound() -> Response { error(.notFound, "not_found") }

    static func badRequest(_ message: String) -> Response {
        error(.badRequest, "bad_request", message: message)
    }

    static func noContent() -> Response { Response(status: .noContent) }

    /// Maps backend and file errors to JSON; nothing reaches Hummingbird's bare 500.
    static func from(_ failure: any Error) -> Response {
        switch failure {
        case BackendError.notFound:
            return notFound()
        case BackendError.busy(let message):
            return error(.conflict, "busy", message: message)
        case BackendError.refused(let code, let message):
            return error(.conflict, code, message: message)
        case BackendError.nothingToSave:
            return error(.conflict, "nothing_to_save", message: "No note yet. Transcribe the session first.")
        case BackendError.unavailable:
            return error(.serviceUnavailable, "unavailable", message: "CallCapture is quitting. Open it again.")
        default:
            logger.error("API request failed: \(failure.localizedDescription)")
            return error(.internalServerError, "failed", message: failure.localizedDescription)
        }
    }

    private static func body(_ data: Data, status: HTTPResponse.Status) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
