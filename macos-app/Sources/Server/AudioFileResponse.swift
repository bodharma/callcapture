import Foundation
import HTTPTypes
import Hummingbird

/// Session audio for the `<audio>` element: single byte ranges, streamed from
/// disk in 64 KB chunks on NIO's thread pool (the file is never loaded whole).
enum AudioFileResponse {
    static let chunkLength = 64 * 1024
    private static let fileIO = FileIO()

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "wav": "audio/wav"
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "caf": "audio/x-caf"
        default: "application/octet-stream"
        }
    }

    static func respond(path: String, rangeHeader: String?, context: some RequestContext) async -> Response {
        guard let size = regularFileSize(path) else { return APIResponse.notFound() }
        var headers: HTTPFields = [
            .contentType: contentType(forExtension: (path as NSString).pathExtension),
            .acceptRanges: "bytes",
            // Private recordings stay out of the browser's disk cache.
            .cacheControl: "no-store",
        ]
        let status: HTTPResponse.Status
        let range: ClosedRange<Int>
        switch HTTPRange.parse(rangeHeader, size: size) {
        case .unsatisfiable:
            var response = APIResponse.error(.rangeNotSatisfiable, "range_not_satisfiable")
            response.headers[.contentRange] = HTTPRange.unsatisfiedRange(size: size)
            response.headers[.acceptRanges] = "bytes"
            return response
        case .full:
            guard size > 0 else { return Response(status: .ok, headers: headers, body: .init()) }
            (status, range) = (.ok, 0...(size - 1))
        case .partial(let requested):
            headers[.contentRange] = HTTPRange.contentRange(requested, size: size)
            (status, range) = (.partialContent, requested)
        }
        do {
            let body = try await fileIO.loadFile(
                path: path, range: range, context: context, chunkLength: chunkLength)
            return Response(status: status, headers: headers, body: body)
        } catch {
            // Removed between the size check and the open.
            return APIResponse.notFound()
        }
    }

    private static func regularFileSize(_ path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }
}
