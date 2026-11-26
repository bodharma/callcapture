import SwiftUI

/// Sessions in a NavigationSplitView. With no query the sidebar lists recent
/// sessions; a query searches titles, dates, transcripts and notes of every
/// session, and choosing a hit opens that session at the matching moment.
@available(macOS 14.2, *)
struct SessionListView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    @State private var selectedSessionID: String?
    @State private var selectedHitID: String?
    @State private var hits: [SearchHit] = []
    @State private var isSearchRunning = false
    @State private var focusTime: Double?

    private var isSearching: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= SessionSearch.minQueryLength
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if isSearching {
                    searchResults
                } else if sortedSessions.isEmpty {
                    emptyState(title: "No Sessions", systemImage: "waveform.slash",
                               message: "Record your first session from the menu bar.")
                } else {
                    sessionList
                }
            }
            .navigationTitle("Sessions")
            .searchable(text: $searchText, prompt: "Search transcripts and notes")
        } detail: {
            if let id = selectedSessionID, let session = session(id: id) {
                // Identity is the session only: another hit in the same session moves the
                // player via focusTime without discarding in-progress detail state.
                SessionDetailView(session: session, focusTime: focusTime)
                    .id(session.id)
            } else {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "waveform",
                    description: Text("Select a session from the sidebar to view details.")
                )
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .task(id: searchText) { await runSearch() }
        .onChange(of: selectedSessionID) { _, id in
            if !isSearching, id != nil { focusTime = nil }
        }
        .onChange(of: selectedHitID) { _, id in
            guard let hit = hits.first(where: { $0.id == id }) else { return }
            focusTime = hit.time
            selectedSessionID = hit.sessionID
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        List(sortedSessions, selection: $selectedSessionID) { session in
            SessionRowView(session: session)
                .tag(session.id)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if hits.isEmpty {
            if isSearchRunning {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState(title: "No Results", systemImage: "magnifyingglass",
                           message: "Nothing in titles, transcripts or notes matches \"\(searchText)\".")
            }
        } else {
            List(hits, selection: $selectedHitID) { hit in
                SearchHitRow(hit: hit).tag(hit.id)
            }
        }
    }

    private func emptyState(title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }

    private var sortedSessions: [Session] {
        appModel.sessionManager.recentSessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// Search hits can point past the 50 sessions kept in `recentSessions`.
    private func session(id: String) -> Session? {
        appModel.sessionManager.recentSessions.first { $0.id == id }
            ?? appModel.sessionManager.session(id: id)
    }

    /// Debounced; a newer keystroke cancels this task and its scan.
    private func runSearch() async {
        guard isSearching else {
            hits = []
            selectedHitID = nil
            isSearchRunning = false
            return
        }
        isSearchRunning = true
        // A superseded search must not clear the flag its replacement just set.
        defer { if !Task.isCancelled { isSearchRunning = false } }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let found = await SessionSearch.search(searchText, sessions: appModel.sessionManager.allSessions())
        guard !Task.isCancelled else { return }
        // Hit ids are positional, so a kept selection could silently point at a different hit.
        selectedHitID = nil
        hits = found
    }
}

@available(macOS 14.2, *)
private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hit.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let time = hit.time {
                    Text(TranscriptDocument.timestamp(time))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(hit.excerpt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }
}
