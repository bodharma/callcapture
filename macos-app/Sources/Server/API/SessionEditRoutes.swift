import Foundation
import Hummingbird

/// Editing a session's details and opening its note.
///
/// | Route | Answer |
/// |---|---|
/// | `GET /api/sessions/options` | `{recordingTypes: [{value, label}], languages: [{value, label}]}` |
/// | `PATCH /api/sessions/:id` | any of `recordingType`, `language`, `notesLanguage`; all or nothing; the updated `SessionDTO`; 400 `invalid` |
/// | `POST /api/sessions/:id/open-note` | 204, or 404 `no_note` |
func addEditRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.get("api/sessions/options") { _, _ in APIResponse.json(SessionOptions.current) }
    router.patch("api/sessions/:id") { request, context in
        await withSession(context, backend) { session in
            let change: SessionDetailsChange
            switch SessionDetailsChange.parse(try? await RequestBody.data(request)) {
            case .failure(let problem):
                return APIResponse.error(.badRequest, "invalid", message: problem.message, key: problem.key)
            case .success(let parsed):
                change = parsed
            }
            try await backend.updateDetails(id: session.id, change)
            await backend.events.publish(.sessionChanged(id: session.id))
            guard let updated = await backend.session(id: session.id) else { return APIResponse.notFound() }
            return APIResponse.json(await detailDTO(updated, backend))
        }
    }
    router.post("api/sessions/:id/open-note") { _, context in
        await withSession(context, backend) { session in
            // The path is the record's own; nothing from the request reaches the file system.
            guard SessionFiles.exists(session.transcriptMarkdownPath) else {
                return APIResponse.error(.notFound, "no_note", message: "This session has no Markdown note yet.")
            }
            try await backend.openNote(id: session.id)
            return APIResponse.noContent()
        }
    }
}

/// The choices the web shows, straight from the app's enums.
struct SessionOptions: Encodable {
    struct Option: Encodable {
        let value: String
        let label: String
    }

    let recordingTypes: [Option]
    let languages: [Option]

    static let current = SessionOptions(
        recordingTypes: RecordingType.allCases.map { Option(value: $0.rawValue, label: $0.displayName) },
        languages: SpokenLanguage.allCases.map { Option(value: $0.rawValue, label: $0.displayName) })
}

extension SessionDetailsChange {
    struct Problem: Error, Equatable {
        let message: String
        let key: String?
    }

    private static let editable = ["recordingType", "language", "notesLanguage"]

    /// All or nothing: a bad body, an unknown key or a value the app doesn't know refuses the whole change.
    static func parse(_ data: Data?) -> Result<SessionDetailsChange, Problem> {
        let hint = "Send {\"recordingType\": …, \"language\": …, \"notesLanguage\": …} with at least one of them."
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !object.isEmpty
        else { return .failure(Problem(message: hint, key: nil)) }
        if let unknown = object.keys.sorted().first(where: { !editable.contains($0) }) {
            return .failure(Problem(message: "\(unknown) can't be changed here. \(hint)", key: unknown))
        }
        var change = SessionDetailsChange()
        for key in editable {
            guard let raw = object[key] else { continue }
            let allowed = (key == "recordingType" ? RecordingType.allCases.map(\.rawValue) : SpokenLanguage.allCases.map(\.rawValue))
            guard let value = raw as? String, allowed.contains(value) else {
                return .failure(Problem(message: "That isn't a value CallCapture knows for \(key).", key: key))
            }
            switch key {
            case "recordingType": change.recordingType = value
            case "language": change.language = value
            default: change.notesLanguage = value
            }
        }
        return .success(change)
    }
}
