import Foundation

/// Why a role's chosen OpenRouter model may not work; shown by the web settings API.
enum ModelSelectionWarning {
    static func text(role: LLMRole, selection: String, snapshot: ModelCatalogSnapshot?, isOnline: Bool) -> String? {
        guard let snapshot else {
            return isOnline ? nil : "Needs internet to load the model list. Current choice: \(selection)."
        }
        guard !selection.isEmpty else { return "Choose a model." }
        guard let selected = snapshot.model(id: selection) else {
            return "\(selection) is no longer offered by OpenRouter. Choose another model."
        }
        if role == .live, !selected.supportsJSON {
            return "\(selected.name) does not support JSON output, which automatic live notes need."
        }
        return nil
    }
}
