import Foundation
import Hummingbird

/// `GET /api/system` → `{"online": Bool, "recording": Bool, "version": String}`.
func addSystemRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.get("api/system") { _, _ in
        APIResponse.json(await backend.systemStatus())
    }
}
