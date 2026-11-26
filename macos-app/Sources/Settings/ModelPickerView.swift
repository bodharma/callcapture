import SwiftUI

/// One role's model choice: the selected model with its estimated hourly cost, opening
/// a sortable table of OpenRouter's current models with prices and independent scores.
@available(macOS 14.2, *)
struct ModelPickerView: View {
    let role: LLMRole
    @Binding var selection: String
    let snapshot: ModelCatalogSnapshot?
    let isOnline: Bool
    let refresh: () -> Void

    @State private var showingTable = false

    private var selected: CatalogModel? { snapshot?.model(id: selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(role == .live ? "Live notes model" : "Final notes model")
                Spacer()
                if let selected {
                    Text("≈ \(ModelPickerFormat.usd(ModelCostEstimate.hourlyUSD(selected, role: role))) / meeting hour")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(ModelCostEstimate.explanation)
                }
                Button(selected?.name ?? (selection.isEmpty ? "Choose…" : selection)) { showingTable = true }
                    .disabled(snapshot == nil)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .sheet(isPresented: $showingTable) {
            ModelTableSheet(role: role, selection: $selection, snapshot: snapshot,
                            isOnline: isOnline, refresh: refresh)
        }
    }

    private var warning: String? {
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

/// "Model list as of … · Refresh" plus any refresh problem; shown once under both rows.
@available(macOS 14.2, *)
struct ModelCatalogStatusRow: View {
    let snapshot: ModelCatalogSnapshot?
    let problem: String?
    let refreshing: Bool
    let isOnline: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let snapshot {
                    Text("Model list as of \(snapshot.modelsFetchedAt.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Model list not loaded yet")
                }
                Spacer()
                if refreshing { ProgressView().controlSize(.small) }
                Button("Refresh", action: refresh)
                    .disabled(!isOnline || refreshing)
            }
            if !isOnline {
                Text("Offline — refreshing needs an internet connection.")
            } else if let problem {
                Text(problem)
            }
            if let scoresProblem = snapshot?.scoresProblem {
                Text(scoresProblem)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

enum ModelPickerFormat {
    static func usd(_ value: Double) -> String {
        switch value {
        case 0: "free"
        case ..<0.01: String(format: "$%.4f", value)
        case ..<10: String(format: "$%.2f", value)
        default: String(format: "$%.0f", value)
        }
    }

    static func score(_ value: Double?, fraction: Bool = false) -> String {
        guard let value else { return "—" }
        return fraction ? String(format: "%.2f", value) : String(format: "%.0f", value)
    }
}

/// Row values for sorting; missing scores sort below every real score.
private struct ModelRow: Identifiable {
    let id: String
    let name: String
    let liveCost: Double
    let finalCost: Double
    let intelligence: Double
    let multilingual: Double
    let strategy: Double
    let context: Int
    let tags: String
    let scores: ModelScores?

    init(_ model: CatalogModel, among models: [CatalogModel]) {
        id = model.id
        name = model.name
        liveCost = ModelCostEstimate.hourlyUSD(model, role: .live)
        finalCost = ModelCostEstimate.hourlyUSD(model, role: .final)
        intelligence = model.scores?.intelligence ?? -1
        multilingual = model.scores?.multilingual ?? -1
        strategy = model.scores?.strategyAndOps ?? -1
        context = model.contextLength
        tags = ModelTags.tags(for: model, among: models).joined(separator: ", ")
        scores = model.scores
    }
}

@available(macOS 14.2, *)
private struct ModelTableSheet: View {
    let role: LLMRole
    @Binding var selection: String
    let snapshot: ModelCatalogSnapshot?
    let isOnline: Bool
    let refresh: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var jsonOnly: Bool
    @State private var sortOrder: [KeyPathComparator<ModelRow>]
    @State private var picked: String?

    init(role: LLMRole, selection: Binding<String>, snapshot: ModelCatalogSnapshot?,
         isOnline: Bool, refresh: @escaping () -> Void) {
        self.role = role
        self._selection = selection
        self.snapshot = snapshot
        self.isOnline = isOnline
        self.refresh = refresh
        _jsonOnly = State(initialValue: role == .live)
        _sortOrder = State(initialValue: [KeyPathComparator(role == .live ? \ModelRow.liveCost : \ModelRow.finalCost)])
        _picked = State(initialValue: selection.wrappedValue)
    }

    private var rows: [ModelRow] {
        let models = snapshot?.models ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        return models
            .filter { !jsonOnly || $0.supportsJSON }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
            .map { ModelRow($0, among: models) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(role == .live ? "Live notes model" : "Final notes model").font(.headline)
            HStack {
                TextField("Search models", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Works for live notes (JSON)", isOn: $jsonOnly)
            }
            Table(rows, selection: $picked, sortOrder: $sortOrder) {
                TableColumn("Model", value: \.name) { Text($0.name).help($0.id) }
                TableColumn("Live / h", value: \.liveCost) { Text(ModelPickerFormat.usd($0.liveCost)).monospacedDigit() }
                TableColumn("Final / h", value: \.finalCost) { Text(ModelPickerFormat.usd($0.finalCost)).monospacedDigit() }
                TableColumn("Intelligence", value: \.intelligence) { scoreCell(ModelPickerFormat.score($0.scores?.intelligence)) }
                TableColumn("Multilingual", value: \.multilingual) { scoreCell(ModelPickerFormat.score($0.scores?.multilingual, fraction: true)) }
                TableColumn("Strategy & Ops", value: \.strategy) { scoreCell(ModelPickerFormat.score($0.scores?.strategyAndOps)) }
                TableColumn("Context", value: \.context) { Text("\($0.context / 1000)k").monospacedDigit() }
                TableColumn("Best for") { Text($0.tags).help(ModelTags.rules) }
            }
            .frame(minHeight: 320)
            VStack(alignment: .leading, spacing: 2) {
                if let citation = snapshot?.scoresCitation { Text(citation) }
                Text(ModelCostEstimate.explanation)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack {
                ModelCatalogStatusRow(snapshot: snapshot, problem: nil, refreshing: false, isOnline: isOnline, refresh: refresh)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use model") {
                    if let picked { selection = picked }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked == nil)
            }
        }
        .padding()
        .frame(minWidth: 860, minHeight: 520)
    }

    private func scoreCell(_ text: String) -> some View {
        Text(text).monospacedDigit().help(text == "—" ? "No independent score" : "Artificial Analysis")
    }
}
