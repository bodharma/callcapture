/// Everything the local web UI is allowed to ask of the app.
///
/// Empty for now: later tasks add one requirement per capability the API
/// exposes, so the HTTP layer never reaches into `AppModel` directly.
protocol AppBackend: Sendable {}

/// Production backend. Capabilities are added here as the API grows.
struct AppModelBackend: AppBackend {}
