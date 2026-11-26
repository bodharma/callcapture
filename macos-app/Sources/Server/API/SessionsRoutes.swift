import Foundation
import HTTPTypes
import Hummingbird

/// `/api/sessions/*` and `/api/search`.
///
/// Every `:id` is looked up through the backend first (unknown → 404
/// `{"error":"not_found"}`); file paths come only from the resulting `Session`
/// record, never from the request. Every error is answered as JSON.
func addSessionsRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.get("api/sessions") { _, _ in
        APIResponse.json(await backend.sessions().map(SessionDTO.init))
    }
    router.get("api/search") { request, _ in
        let query = request.uri.queryParameters["q"].map(String.init) ?? ""
        return APIResponse.json(await backend.search(query).map(SearchHitDTO.init))
    }
    router.get("api/sessions/:id") { _, context in
        await withSession(context, backend) { APIResponse.json(SessionDTO($0)) }
    }
    router.delete("api/sessions/:id") { _, context in
        await withSession(context, backend) { session in
            try await backend.delete(id: session.id)
            return APIResponse.noContent()
        }
    }
    addReadRoutes(to: router, backend: backend)
    addSpeakerRoutes(to: router, backend: backend)
    addMediaRoutes(to: router, backend: backend)
    addActionRoutes(to: router, backend: backend)
}

private func addReadRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.get("api/sessions/:id/transcript") { _, context in
        await withSession(context, backend) { session in
            let names = try await backend.speakerNames(id: session.id)
            let lines = try await backend.transcript(id: session.id)
            return APIResponse.json(lines.map { TranscriptLineDTO($0, names: names) })
        }
    }
    router.get("api/sessions/:id/note") { _, context in
        await withSession(context, backend) { session in
            let names = try await backend.speakerNames(id: session.id)
            return APIResponse.json(NoteDTO(markdown: await backend.note(id: session.id).map(names.apply(to:))))
        }
    }
    router.get("api/sessions/:id/analysis") { _, context in
        await withSession(context, backend) { session in
            let names = try await backend.speakerNames(id: session.id)
            return APIResponse.json(await backend.analysis(id: session.id).map { AnalysisDTO($0, names: names) })
        }
    }
    router.get("api/sessions/:id/markers") { _, context in
        await withSession(context, backend) { session in
            APIResponse.json(TapeMarkers.from(try await backend.liveDocument(id: session.id)))
        }
    }
    router.get("api/sessions/:id/export") { request, context in
        await withSession(context, backend) { session in
            guard let raw = request.uri.queryParameters["format"],
                let format = SessionExport.Format(rawValue: String(raw))
            else { return APIResponse.badRequest("format must be md, txt or json.") }
            guard let source = SessionExport.sourcePath(for: format, session: session), SessionFiles.exists(source)
            else {
                return APIResponse.error(
                    .conflict, "nothing_to_export", message: "Nothing to export yet. Transcribe the session first.")
            }
            let names = try await backend.speakerNames(id: session.id)
            let data = try SessionExport.data(from: source, format: format, names: names)
            return Response(
                status: .ok,
                headers: [
                    .contentType: exportContentType(format),
                    .contentDisposition: ContentDisposition.attachment(
                        title: session.title, fileExtension: format.rawValue),
                    .cacheControl: "no-store",
                ],
                body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }
    }
}

private func addSpeakerRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.get("api/sessions/:id/speakers") { _, context in
        await withSession(context, backend) { session in
            let names = try await backend.speakerNames(id: session.id)
            return APIResponse.json(try await knownSpeakers(session, backend, names: names))
        }
    }
    router.put("api/sessions/:id/speakers/:label") { request, context in
        await withSession(context, backend) { session in
            guard let label = context.parameters.get("label")?.removingPercentEncoding,
                try await knownSpeakers(session, backend, names: SpeakerNames()).contains(where: { $0.label == label })
            else { return APIResponse.notFound() }
            guard let body = try? await decodeJSON(RenameBody.self, from: request) else {
                return APIResponse.badRequest(#"Send {"name": "…"}; an empty name restores the label."#)
            }
            try await backend.renameSpeaker(id: session.id, label: label, name: body.name)
            return APIResponse.noContent()
        }
    }
}

private func addMediaRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.get("api/sessions/:id/audio") { request, context in
        await withSession(context, backend) { session in
            // Several Range fields are as ambiguous as a multi-range: serve the whole file.
            let ranges = request.headers[values: .range]
            return await AudioFileResponse.respond(
                path: session.audioPath, rangeHeader: ranges.count == 1 ? ranges[0] : nil, context: context)
        }
    }
    router.get("api/sessions/:id/peaks") { _, context in
        await withSession(context, backend) { session in
            let path = session.audioPath
            guard SessionFiles.exists(path) else { return APIResponse.notFound() }
            let peaks = try await Blocking.run {
                try WaveformPeaks.load(audioPath: path, buckets: WaveformPeaks.defaultBuckets)
            }
            return APIResponse.json(peaks)
        }
    }
}

private func addActionRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.post("api/sessions/:id/reprocess") { _, context in
        await withSession(context, backend) { session in
            APIResponse.json(ReprocessDTO(error: await backend.reprocess(id: session.id)))
        }
    }
    router.post("api/sessions/:id/vault") { _, context in
        await withSession(context, backend) { session in
            APIResponse.json(VaultDTO(path: try await backend.saveToVault(id: session.id).path))
        }
    }
    router.post("api/sessions/:id/reveal") { _, context in
        await withSession(context, backend) { session in
            try await backend.revealInFinder(id: session.id)
            return APIResponse.noContent()
        }
    }
}

// MARK: Helpers

/// Resolves `:id` to a session (404 JSON if unknown) and maps any thrown error to JSON.
private func withSession(
    _ context: BasicRequestContext, _ backend: any AppBackend,
    _ handle: (Session) async throws -> Response
) async -> Response {
    guard let id = context.parameters.get("id")?.removingPercentEncoding,
        let session = await backend.session(id: id)
    else { return APIResponse.notFound() }
    do {
        return try await handle(session)
    } catch {
        return APIResponse.from(error)
    }
}

private func knownSpeakers(
    _ session: Session, _ backend: any AppBackend, names: SpeakerNames
) async throws -> [SpeakerDTO] {
    SpeakerDTO.list(
        lines: try await backend.transcript(id: session.id),
        analysis: await backend.analysis(id: session.id), names: names)
}

private struct RenameBody: Decodable {
    let name: String
}

private let maxJSONBodyBytes = 16 * 1024

private func decodeJSON<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T {
    let buffer = try await request.body.collect(upTo: maxJSONBodyBytes)
    return try JSONDecoder().decode(type, from: Data(buffer.readableBytesView))
}

private func exportContentType(_ format: SessionExport.Format) -> String {
    switch format {
    case .md: "text/markdown; charset=utf-8"
    case .txt: "text/plain; charset=utf-8"
    case .json: "application/json; charset=utf-8"
    }
}
