import AppKit

/// The folder chooser behind `POST /api/system/pick-folder`. The request may come from
/// the user's browser, so the app activates itself and floats the panel above other
/// windows. The panel is shown with `begin`, not `runModal`, so the main actor keeps
/// serving other requests (status polls) while it is open.
@MainActor
final class FolderPicker {
    static let shared = FolderPicker()

    private var isOpen = false

    /// The chosen folder's path, or nil when the user cancels.
    func choose(message: String, startingAt path: String) async throws -> String? {
        guard !isOpen else {
            throw BackendError.busy("A folder chooser is already open. Choose a folder there or cancel it first.")
        }
        isOpen = true
        defer { isOpen = false }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "Choose"
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        panel.level = .floating
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
            panel.orderFrontRegardless()
        }
        return response == .OK ? panel.url?.path : nil
    }
}
