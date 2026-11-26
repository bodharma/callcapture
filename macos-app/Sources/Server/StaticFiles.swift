import Foundation
import Hummingbird

/// Where the built web UI lives: `$CALLCAPTURE_WEB_DIR` when set (dev), else
/// `Contents/Resources/web` inside the app bundle.
func defaultWebDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main
) -> URL? {
    if let override = environment["CALLCAPTURE_WEB_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return bundle.resourceURL?.appendingPathComponent("web", isDirectory: true)
}

/// Serves the built web app. Any GET that is not under `/api` and does not
/// name a real file gets `index.html` (client-side routing). Registered as
/// catch-all routes, so concrete routes such as `/login` win.
func addStaticRoutes(to router: Router<BasicRequestContext>, webDirectory: URL?) {
    let files = StaticFiles(root: webDirectory)
    router.get("") { request, _ in files.respond(to: request.uri.path) }
    // The trie does not backtrack out of the concrete `api/...` routes, so
    // unknown API paths need their own catch-all (404 JSON, never index.html).
    router.get("api/**") { request, _ in files.respond(to: request.uri.path) }
    router.get("**") { request, _ in files.respond(to: request.uri.path) }
}

struct StaticFiles: Sendable {
    let root: URL?

    func respond(to rawPath: String) -> Response {
        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if segments.first == "api" { return notFoundJSON() }
        guard let root, let index = existingFile(root.appendingPathComponent("index.html"), in: root)
        else { return unavailable() }
        if let file = resolve(segments, in: root) { return serve(file, isIndex: false) }
        return serve(index, isIndex: true)
    }

    /// Maps URL segments to a regular file inside `root`, or nil. Segments are
    /// percent-decoded first; any `..`, separator or NUL after decoding rejects
    /// the whole request, and the resolved real path must still be under `root`.
    private func resolve(_ segments: [String], in root: URL) -> URL? {
        var url = root
        for raw in segments {
            guard let part = raw.removingPercentEncoding, !part.isEmpty, part != "..",
                !part.contains("/"), !part.contains("\\"), !part.contains("\0")
            else { return nil }
            if part == "." { continue }
            url.appendPathComponent(part)
        }
        return existingFile(url, in: root)
    }

    /// Returns `url` (symlinks resolved) only when it is a regular file under `root`.
    private func existingFile(_ url: URL, in root: URL) -> URL? {
        let real = url.resolvingSymlinksInPath().standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard real.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else { return nil }
        return real
    }

    private func serve(_ file: URL, isIndex: Bool) -> Response {
        guard let data = try? Data(contentsOf: file) else { return unavailable() }
        return Response(
            status: .ok,
            headers: [
                .contentType: Self.contentType(for: file.pathExtension),
                .cacheControl: isIndex ? "no-cache" : "public, max-age=3600",
            ],
            body: .init(byteBuffer: .init(data: data)))
    }

    private func unavailable() -> Response {
        Response(
            status: .serviceUnavailable,
            headers: [.contentType: "text/plain; charset=utf-8"],
            body: .init(byteBuffer: .init(string: "Web UI not built")))
    }

    private func notFoundJSON() -> Response {
        Response(
            status: .notFound,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: .init(string: #"{"error":"not_found"}"#)))
    }

    private static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
