import Foundation
import Hummingbird

/// `GET /api/system` → `{"online": Bool, "recording": Bool, "version": String}`.
/// `POST /api/system/pick-folder` `{"setting": "outputDirectory" | "obsidianVault"}` →
/// `{"path": String}`, or `{"path": null}` when cancelled. The app shows `NSOpenPanel`
/// even when the request came from the browser. The pick saves nothing: the UI sends the
/// path through `PATCH /api/settings`, so it is checked like a typed path.
func addSystemRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.get("api/system") { _, _ in
        APIResponse.json(await backend.systemStatus())
    }
    router.post("api/system/pick-folder") { request, _ in
        guard let body = try? await RequestBody.decode(PickFolderBody.self, from: request),
            let setting = FolderSetting(rawValue: body.setting)
        else {
            let allowed = FolderSetting.allCases.map(\.rawValue).joined(separator: ", ")
            return invalidResponse("setting must be one of: \(allowed).", key: "setting")
        }
        return await apiResult { APIResponse.json(PickedFolderDTO(path: try await backend.pickFolder(for: setting))) }
    }
}

private struct PickFolderBody: Decodable {
    let setting: String
}

/// Encodes a cancelled pick as `"path": null`, not as a missing key.
private struct PickedFolderDTO: Encodable {
    let path: String?

    enum CodingKeys: String, CodingKey { case path }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
    }
}
