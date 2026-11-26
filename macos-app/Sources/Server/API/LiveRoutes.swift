import Foundation
import Hummingbird

/// The live map over HTTP. Every action is registered twice: under `/api/live/…` for
/// the meeting being recorded (409 `no_live_meeting` otherwise) and under
/// `/api/sessions/:id/live/…` for a session's saved map (404 without one).
///
/// | Route | Body | Model method |
/// |---|---|---|
/// | `GET /api/live` | | `LiveViewDTO`, or `{"active": false, "lastSessionID"?}` |
/// | `GET /api/sessions/:id/live` | | `LiveViewDTO` of the saved map |
/// | `POST …/note` | `{text, kind, topicID?}` | `addManualNote` |
/// | `POST …/catch-up` | | `catchUp` |
/// | `POST …/back-to-live` | | `backToLive` |
/// | `POST …/notes-language` | `{code}` | `setNotesLanguage` |
/// | `POST …/topics` | `{title, parentID?}` | `addTopic` |
/// | `POST …/topics/:topic/select` | | `selectTopic` |
/// | `POST …/topics/:topic/rename` | `{title}` | `renameTopic` |
/// | `POST …/topics/:topic/move` | `{parentID: id or null}` | `moveTopic` |
/// | `POST …/topics/:topic/merge` | `{targetID}` | `mergeTopic` |
/// | `POST …/topics/:topic/pin` | `{pinned}` | `pinTopic` |
/// | `POST …/memos/:topic/:memo/edit` | `{text}` | `editMemo` |
/// | `POST …/memos/:topic/:memo/pin` | `{pinned}` | `pinMemo` |
/// | `POST …/export` | | `exportMarkdown(to:)` after a folder chooser → `{"path": … or null}` |
///
/// Actions answer 204. Unknown topic or memo ids are 404; a change the model would
/// refuse (a cycle, a self-merge) is 409 `refused` with the reason; a bad body is 400
/// `invalid` with the field in `key`.
func addLiveRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.get("api/live") { _, _ in
        await apiResult {
            guard let view = try await backend.liveView(.current), view.live else {
                return APIResponse.json(InactiveLiveDTO(lastSessionID: try await lastSessionID(backend)))
            }
            return APIResponse.json(LiveViewDTO(view))
        }
    }
    router.get("api/sessions/:id/live") { _, context in
        await liveResult {
            guard let id = sessionID(context), let view = try await backend.liveView(.session(id)) else {
                throw LiveActionError.notFound
            }
            return APIResponse.json(LiveViewDTO(view))
        }
    }
    for (path, parse) in liveActionRoutes {
        router.post(RouterPath("api/live/" + path)) { request, context in
            await perform(request, context, backend, target: { _ in .current }, parse: parse)
        }
        router.post(RouterPath("api/sessions/:id/live/" + path)) { request, context in
            await perform(request, context, backend, target: { sessionID($0).map(LiveTarget.session) }, parse: parse)
        }
    }
}

private typealias ActionParser = (BasicRequestContext, LiveBody) throws -> LiveAction

private let liveActionRoutes: [(String, ActionParser)] = [
    ("note", { _, body in
        .addNote(
            text: try body.text("text", max: LiveBody.maxNote), kind: try body.kind("kind"),
            topicID: try body.optionalID("topicID"))
    }),
    ("catch-up", { _, _ in .catchUp }),
    ("back-to-live", { _, _ in .backToLive }),
    ("notes-language", { _, body in .setNotesLanguage(try body.languageCode("code")) }),
    ("topics", { _, body in
        .addTopic(title: try body.text("title", max: LiveBody.maxTitle), parentID: try body.optionalID("parentID"))
    }),
    ("topics/:topic/select", { context, _ in .selectTopic(try pathID(context, "topic")) }),
    ("topics/:topic/rename", { context, body in
        .renameTopic(try pathID(context, "topic"), title: try body.text("title", max: LiveBody.maxTitle))
    }),
    ("topics/:topic/move", { context, body in
        .moveTopic(try pathID(context, "topic"), parentID: try body.optionalID("parentID", required: true))
    }),
    ("topics/:topic/merge", { context, body in
        .mergeTopic(try pathID(context, "topic"), into: try body.id("targetID"))
    }),
    ("topics/:topic/pin", { context, body in .pinTopic(try pathID(context, "topic"), pinned: try body.bool("pinned")) }),
    ("memos/:topic/:memo/edit", { context, body in
        .editMemo(
            topicID: try pathID(context, "topic"), memoID: try pathID(context, "memo"),
            text: try body.text("text", max: LiveBody.maxNote))
    }),
    ("memos/:topic/:memo/pin", { context, body in
        .pinMemo(topicID: try pathID(context, "topic"), memoID: try pathID(context, "memo"), pinned: try body.bool("pinned"))
    }),
    ("export", { _, _ in .export }),
]

private func perform(
    _ request: Request, _ context: BasicRequestContext, _ backend: any AppBackend,
    target: (BasicRequestContext) -> LiveTarget?, parse: ActionParser
) async -> Response {
    guard let target = target(context) else { return APIResponse.notFound() }
    let action: LiveAction
    do {
        action = try parse(context, LiveBody(try await RequestBody.data(request)))
    } catch let invalid as LiveBody.Invalid {
        return invalidResponse(invalid.message, key: invalid.key)
    } catch is LiveActionError {
        return APIResponse.notFound()
    } catch {
        return invalidResponse("Send at most 16 KB of JSON.")
    }
    return await liveResult {
        switch try await backend.performLive(action, on: target) {
        case .done:
            await backend.events.publish(.liveDocument(sessionID: try await liveSessionID(target, backend)))
            return APIResponse.noContent()
        case .exported(let path):
            return APIResponse.json(ExportedDTO(path: path))
        }
    }
}

/// So every open page refetches at once, even before the app's throttled event.
private func liveSessionID(_ target: LiveTarget, _ backend: any AppBackend) async throws -> String {
    switch target {
    case .session(let id): return id
    case .current: return try await backend.liveView(.current)?.document.sessionID ?? ""
    }
}

private func lastSessionID(_ backend: any AppBackend) async throws -> String? {
    guard let id = try await backend.liveView(.current)?.document.sessionID, !id.isEmpty else { return nil }
    return id
}

private func liveResult(_ handle: () async throws -> Response) async -> Response {
    do {
        return try await handle()
    } catch LiveActionError.noLiveMeeting {
        return APIResponse.error(
            .conflict, "no_live_meeting",
            message: "No live meeting is running. Start a recording with the live map turned on.")
    } catch LiveActionError.notFound {
        return APIResponse.notFound()
    } catch LiveActionError.refused(let reason) {
        return APIResponse.error(.conflict, "refused", message: reason)
    } catch {
        return APIResponse.from(error)
    }
}

private func sessionID(_ context: BasicRequestContext) -> String? {
    context.parameters.get("id")?.removingPercentEncoding
}

/// A topic or memo id from the path; anything no model id could be is simply unknown.
private func pathID(_ context: BasicRequestContext, _ name: String) throws -> String {
    guard let id = context.parameters.get(name)?.removingPercentEncoding, !id.isEmpty, id.count <= LiveBody.maxID
    else { throw LiveActionError.notFound }
    return id
}

/// Encodes a cancelled export as `"path": null`.
private struct ExportedDTO: Encodable {
    let path: String?

    enum CodingKeys: String, CodingKey { case path }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
    }
}
