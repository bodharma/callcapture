import Foundation
import Hummingbird

/// `GET /api/catalog` → `CatalogDTO`.
/// `POST /api/catalog/refresh` with an optional `{"force": Bool}` (default true; false
/// keeps the 24 h cache, like opening the Settings page) → `CatalogDTO`, or 409
/// `{"error":"offline"}` with the app's wording. A failed refresh still answers 200:
/// the cached models stay and `problem` says why.
func addCatalogRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.get("api/catalog") { _, _ in
        APIResponse.json(CatalogDTO(await backend.catalog()))
    }
    router.post("api/catalog/refresh") { request, _ in
        let force: Bool
        do {
            let data = try await RequestBody.data(request)
            force = data.isEmpty ? true : try JSONDecoder().decode(RefreshBody.self, from: data).force ?? true
        } catch {
            return invalidResponse(#"Send nothing, or {"force": true} / {"force": false}."#)
        }
        guard await backend.isOnline() else {
            return APIResponse.error(.conflict, "offline", message: NetworkPolicy.catalogRefreshOfflineReason)
        }
        await backend.refreshCatalog(force: force)
        await backend.events.publish(.catalog)
        return APIResponse.json(CatalogDTO(await backend.catalog()))
    }
}

private struct RefreshBody: Decodable {
    let force: Bool?
}
