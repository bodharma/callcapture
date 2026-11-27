import SwiftUI
import AppKit

@available(macOS 14.2, *)
struct LiveMeetingWorkspace: View {
    let model: LiveMeetingModel
    var processingStatus: String = "Saved live map"
    var microphoneEnabled: Bool = true
    @State private var manualText = ""
    @State private var manualKind: LiveMemoKind = .note
    @State private var showTranscript = true
    @State private var newTitle = ""
    @State private var newTopicTitle = ""
    @State private var exportMessage: String?
    @FocusState private var noteFocused: Bool

    private var selected: ConversationTopic? {
        model.document.topics.first { $0.id == model.selectedTopicID }
    }
    private var currentTitle: String {
        model.document.topics.first { $0.id == model.document.currentTopicID }?.title ?? "Waiting for committed speech"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.document.title.isEmpty ? "Live meeting" : model.document.title).font(.title2.bold())
                    Text(processingStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Current mapped topic: \(currentTitle)")
                        .font(.subheadline)
                    Text(model.mappedThroughSeconds.map { "Topic map through \(timestamp($0)) · \(model.status)" } ?? model.status)
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("Notes language: \(model.document.resolvedNotesLanguage ?? "awaiting speech detection")")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let usage = model.document.liveNotesUsage {
                        Text(LiveNotesUsageText.line(usage)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if model.document.notesLanguage == "auto" && model.document.resolvedNotesLanguage == nil {
                        Menu("Choose notes language") {
                            ForEach(["en", "uk", "pl", "de", "fr", "es"], id: \.self) { code in
                                Button(code) { model.setNotesLanguage(code) }
                            }
                        }.controlSize(.small)
                    }
                    if !microphoneEnabled { Label("Microphone off · Remote audio only", systemImage: "mic.slash").font(.caption) }
                }
                Spacer()
                Button("What did I miss?") { model.catchUp() }.keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Add thought") { noteFocused = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Back to live") { model.backToLive() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Export…") { export() }
            }
            if !model.followsLive {
                Label("Browsing earlier evidence · live transcript continues (\(model.document.turns.count) committed turns)", systemImage: "bookmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.catchUpText.isEmpty { GroupBox("Catch up") { Text(model.catchUpText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
            if let warning = model.document.warnings.last { Label(warning, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary) }
            HStack {
                TextField("New topic title", text: $newTopicTitle).textFieldStyle(.roundedBorder).frame(maxWidth: 250)
                Button("Add topic") { model.addTopic(title: newTopicTitle); newTopicTitle = "" }
                    .disabled(newTopicTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            HSplitView {
                List {
                    OutlineGroup(topicNodes(parentID: nil), children: \.children) { node in
                        Button { model.selectTopic(node.id) } label: {
                            HStack {
                                Text(node.title).fontWeight(model.selectedTopicID == node.id ? .semibold : .regular)
                                if node.pinned { Image(systemName: "pin.fill").accessibilityLabel("Pinned") }
                                if node.id == model.document.currentTopicID { Text("Live").font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                .frame(minWidth: 180, idealWidth: 230, maxWidth: 320)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let topic = selected {
                            HStack {
                                Text(topic.title).font(.title3.bold())
                                Spacer()
                                Button(topic.pinned ? "Unpin topic" : "Pin topic") { model.pinTopic(topic.id) }
                            }
                            topicControls(topic)
                            if !topic.summary.isEmpty { Text(topic.summary).textSelection(.enabled) }
                            ForEach(topic.memos) { memo in
                                LiveMemoRow(memo: memo, topicID: topic.id, model: model)
                            }
                            GroupBox("Supporting evidence") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(model.document.turns.filter { topic.turnIDs.contains($0.id) }) { turn in
                                        turnView(turn)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            ContentUnavailableView("Waiting for a topic", systemImage: "text.bubble", description: Text("Committed local speech and your notes appear here."))
                        }
                    }.padding(12)
                }.frame(minWidth: 360)
            }.frame(minHeight: 260)
            GroupBox("Your thought or question") {
                HStack(alignment: .top) {
                    Picker("Kind", selection: $manualKind) {
                        ForEach(LiveMemoKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.frame(width: 150)
                    TextField("Write a personal note", text: $manualText, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder).focused($noteFocused)
                    Button("Add") {
                        model.addManualNote(manualText, kind: manualKind)
                        manualText = ""
                    }.disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            DisclosureGroup("Transcript · \(model.document.turns.count) committed turns", isExpanded: $showTranscript) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.document.turns) { turn in turnView(turn) }
                        ForEach([LiveAudioSource.mic, .system], id: \.rawValue) { source in
                            if let partial = model.partials[source], !partial.isEmpty {
                                Text("\(source == .mic ? "You" : "Remote audio") · partial: \(partial)")
                                    .font(.callout).italic().foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 90, maxHeight: 180)
            }
            if let exportMessage { Text(exportMessage).font(.caption).textSelection(.enabled) }
        }
        .padding(16)
        .frame(minWidth: 850, minHeight: 650)
    }

    @ViewBuilder private func topicControls(_ topic: ConversationTopic) -> some View {
        HStack {
            TextField("New topic title", text: $newTitle).textFieldStyle(.roundedBorder)
            Button("Rename") { model.renameTopic(topic.id, title: newTitle); newTitle = "" }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Menu("Move under") {
                Button("Top level") { model.moveTopic(topic.id, parentID: nil) }
                ForEach(model.document.topics.filter { $0.id != topic.id }) { target in
                    Button(target.title) { model.moveTopic(topic.id, parentID: target.id) }
                }
            }
            Menu("Merge into") {
                ForEach(model.document.topics.filter { $0.id != topic.id }) { target in
                    Button(target.title) { model.mergeTopic(topic.id, into: target.id) }
                }
            }.disabled(model.document.topics.count < 2)
        }
    }

    private func turnView(_ turn: LiveTurn) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(timestamp(turn.start)) · \(turn.source == .mic ? "You" : "Remote audio")")
                .font(.caption).foregroundStyle(.secondary)
            Text(turn.text).font(.callout).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timestamp(_ time: Double) -> String { LiveMeetingModel.timestamp(time) }

    private struct TopicNode: Identifiable {
        let id: String
        let title: String
        let pinned: Bool
        let children: [TopicNode]?
    }
    private func topicNodes(parentID: String?) -> [TopicNode] {
        model.document.topics.filter { $0.parentID == parentID }.map { topic in
            let children = topicNodes(parentID: topic.id)
            return TopicNode(id: topic.id, title: topic.title, pinned: topic.pinned, children: children.isEmpty ? nil : children)
        }
    }
    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export live map"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do { exportMessage = "Saved \(try model.exportMarkdown(to: directory).path)" }
        catch { exportMessage = "Export failed: \(error.localizedDescription)" }
    }
}

@available(macOS 14.2, *)
private struct LiveMemoRow: View {
    let memo: LiveMemo
    let topicID: String
    let model: LiveMeetingModel
    @State private var draft = ""
    @State private var editing = false
    var body: some View {
        GroupBox("\(memo.suggestedRevisionOf != nil ? "Suggested revision ·" : (memo.manual ? "Your" : "Suggested")) \(memo.kind.rawValue)") {
            VStack(alignment: .leading, spacing: 6) {
                if editing {
                    TextField("Memo", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder)
                } else { Text(memo.text).textSelection(.enabled) }
                HStack {
                    Button(editing ? "Save edit" : "Edit") {
                        if editing { model.editMemo(topicID: topicID, memoID: memo.id, text: draft) }
                        else { draft = memo.text }
                        editing.toggle()
                    }
                    Button(memo.pinned ? "Unpin note" : "Pin note") { model.pinMemo(topicID: topicID, memoID: memo.id) }
                    if editing { Button("Cancel", role: .cancel) { editing = false } }
                }.controlSize(.small)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
