import Foundation
import Observation

// Original live evidence is immutable; later batch transcription owns separate files.
enum LiveAudioSource: String, Codable, Sendable { case mic, system }

struct LiveTurn: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let source: LiveAudioSource
    let start: Double
    let end: Double
    let text: String
    let language: String?
}

enum LiveMemoKind: String, Codable, CaseIterable, Sendable { case idea, question, decision, action, note }

struct LiveNotesConfiguration: Sendable {
    let enabled: Bool
    let baseURL: URL
    let apiKey: String
    let model: String
    /// OpenRouter's current model IDs when known; nil skips the "still offered" check
    /// (local servers, or no catalog loaded yet).
    var listedModelIDs: Set<String>? = nil
}

/// Tokens and provider-reported cost of automatic live-notes requests in one meeting.
struct LiveNotesUsage: Codable, Equatable, Sendable {
    var requests = 0
    var promptTokens = 0
    var completionTokens = 0
    var reportedCostUSD = 0.0
    /// Requests whose response carried no cost figure.
    var unpricedRequests = 0

    func adding(_ other: LiveNotesUsage) -> LiveNotesUsage {
        LiveNotesUsage(requests: requests + other.requests, promptTokens: promptTokens + other.promptTokens,
                       completionTokens: completionTokens + other.completionTokens,
                       reportedCostUSD: reportedCostUSD + other.reportedCostUSD,
                       unpricedRequests: unpricedRequests + other.unpricedRequests)
    }
}

struct LiveMemo: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var kind: LiveMemoKind
    var text: String
    var manual: Bool = false
    var pinned: Bool = false
    var turnIDs: [String] = []
    var suggestedRevisionOf: String? = nil
}

struct TopicVisit: Codable, Sendable, Equatable {
    var start: Double
    var end: Double
    var turnIDs: [String]
}

struct ConversationTopic: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var parentID: String? = nil
    var title: String
    var summary: String = ""
    var pinned: Bool = false
    var memos: [LiveMemo] = []
    var turnIDs: [String] = []
    var visits: [TopicVisit] = []
    var manualTitle: Bool = false
    var manualParent: Bool = false
    var isUnassigned: Bool = false
}

struct ConversationDocument: Codable, Sendable, Equatable {
    var schemaVersion = 1
    var sessionID = ""
    var title = ""
    var audioPath = ""
    var turns: [LiveTurn] = []
    var topics: [ConversationTopic] = []
    var currentTopicID: String? = nil
    var warnings: [String] = []
    var isRecording = false
    var speechLanguage = "auto"
    var notesLanguage = "auto"
    var resolvedNotesLanguage: String? = nil
    var arrivalTurnIDs: [String] = []
    var mergedTopicIDs: [String: String] = [:]
    var mappedTurnIDs: [String] = []
    /// Optional so live maps saved before usage tracking still decode.
    var liveNotesUsage: LiveNotesUsage? = nil
}

@MainActor @Observable
final class LiveMeetingModel {
    private(set) var document = ConversationDocument()
    private(set) var selectedTopicID: String?
    private(set) var followsLive = true
    private(set) var catchUpText = ""
    private(set) var status = "Ready"
    private(set) var error: String?
    private(set) var partials: [LiveAudioSource: String] = [:]

    var mappedThroughSeconds: Double? {
        let mapped = Set(document.mappedTurnIDs)
        return document.turns.filter { mapped.contains($0.id) }.map(\.end).max()
    }

    /// Largest sensible audio offset (7 days); anything beyond is rejected as corrupt.
    nonisolated static let maxOffsetSeconds: Double = 7 * 24 * 3600

    private let topicService: ConversationTopicService
    private let coalescingDelay: Duration
    @ObservationIgnored private var configuration: LiveNotesConfiguration?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pendingTurnIDs: [String] = []
    @ObservationIgnored private var catchUpRequestedIDs: [String] = []
    @ObservationIgnored private var departureCursor: Int?
    @ObservationIgnored private var ownedSaveURL: URL?

    private struct WeakModel { weak var model: LiveMeetingModel? }
    private static var registry: [String: WeakModel] = [:]

    /// Single-writer ownership: every holder of one saved map (workspace, history sheet,
    /// controller) shares one instance, so a stale copy can never overwrite newer edits.
    static func opened(audioPath: String) throws -> LiveMeetingModel {
        let key = saveURL(audioPath: audioPath).standardizedFileURL.path
        registry = registry.filter { $0.value.model != nil }
        if let existing = registry[key]?.model { return existing }
        let model = LiveMeetingModel()
        try model.load(audioPath: audioPath)
        return model
    }
    private func register(_ url: URL) {
        Self.registry = Self.registry.filter { $0.value.model !== self && $0.value.model != nil }
        Self.registry[url.standardizedFileURL.path] = WeakModel(model: self)
    }

    nonisolated init(topicService: ConversationTopicService = .init(), coalescingDelay: Duration = .milliseconds(400)) {
        self.topicService = topicService
        self.coalescingDelay = coalescingDelay
    }

    func begin(sessionID: String, title: String, audioPath: String, speechLanguage: String, notesLanguage: String, configuration: LiveNotesConfiguration) throws {
        guard !document.isRecording else { throw ConversationMapError.invalid("A live meeting is already recording.") }
        guard !sessionID.isEmpty, !audioPath.isEmpty, audioPath.hasPrefix("/") else { throw ConversationMapError.invalid("A session ID and absolute audio path are required.") }
        let saveURL = Self.saveURL(audioPath: audioPath)
        guard !FileManager.default.fileExists(atPath: saveURL.path) else { throw ConversationMapError.invalid("A live map already exists beside this audio. Open it instead of replacing it.") }
        let speech = speechLanguage.lowercased()
        let notes = notesLanguage.lowercased()
        var fresh = ConversationDocument()
        fresh.sessionID = sessionID
        fresh.title = title
        fresh.audioPath = audioPath
        fresh.isRecording = true
        fresh.speechLanguage = speech
        fresh.notesLanguage = notes
        fresh.resolvedNotesLanguage = Self.resolvedLanguage(notes == "auto" ? speech : notes)
        // Reserve the new owned file without replacing another session's map.
        try Self.writeNew(JSONEncoder().encode(fresh), to: saveURL)
        resetRuntime()
        document = fresh
        ownedSaveURL = saveURL
        register(saveURL)
        self.configuration = configuration
        status = configuration.enabled ? "Waiting for speech" : "Transcript and manual notes; automatic notes off"
        if configuration.enabled, let problem = configurationProblem(configuration) { error = problem; status = "Automatic notes unavailable" }
        else if configuration.enabled, fresh.resolvedNotesLanguage == nil { status = "Choose notes language; waiting for detected speech language" }
    }

    func ingest(_ turn: LiveTurn) {
        guard document.isRecording else { return }
        guard !document.turns.contains(where: { $0.id == turn.id }) else { return }
        guard Self.validTurn(turn) else { markGap("Invalid live turn was rejected; recover its audio from the recording."); return }
        document.turns.append(turn)
        document.turns.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        document.arrivalTurnIDs.append(turn.id)
        partials[turn.source] = nil
        if document.resolvedNotesLanguage == nil, document.notesLanguage == "auto", let detected = turn.language.flatMap(Self.resolvedLanguage) {
            document.resolvedNotesLanguage = detected
        }
        let discussion = ensureDiscussion()
        document.topics[discussion].turnIDs.append(turn.id)
        rebuildVisits(in: &document)
        if document.turns.last?.id == turn.id { document.currentTopicID = document.topics[discussion].id }
        if followsLive { selectedTopicID = document.currentTopicID }
        pendingTurnIDs.append(turn.id)
        persist()
        scheduleAnalysis()
    }

    func updatePartial(source: LiveAudioSource, text: String) {
        guard document.isRecording else { return }
        partials[source] = String(text.prefix(20_000))
    }

    func markGap(_ message: String) {
        guard !message.isEmpty else { return }
        let bounded = String(message.prefix(1000))
        if document.warnings.last != bounded { document.warnings.append(bounded) }
        status = "Live transcript has a gap; recording continues"
        persist()
    }

    /// Only resolves an unresolved Auto language; manual notes are never rewritten.
    func setNotesLanguage(_ code: String) {
        guard document.notesLanguage == "auto", document.resolvedNotesLanguage == nil,
              let language = Self.resolvedLanguage(code) else { return }
        document.resolvedNotesLanguage = language
        persist()
        if document.isRecording, let configuration, configuration.enabled, configurationProblem(configuration) == nil {
            error = nil
            status = "Live notes (\(language))"
            scheduleAnalysis()
        }
    }

    func addManualNote(_ text: String, kind: LiveMemoKind) {
        guard !document.sessionID.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let index = document.topics.firstIndex { $0.id == (selectedTopicID ?? document.currentTopicID) } ?? ensureDiscussion()
        document.topics[index].memos.append(LiveMemo(id: UUID().uuidString, kind: kind, text: text, manual: true))
        if selectedTopicID == nil { selectedTopicID = document.topics[index].id }
        persist()
    }

    func selectTopic(_ id: String) {
        guard document.topics.contains(where: { $0.id == id }) else { return }
        if followsLive { departureCursor = document.arrivalTurnIDs.count; catchUpText = "" }
        followsLive = false
        selectedTopicID = id
    }

    func backToLive() {
        followsLive = true
        selectedTopicID = document.currentTopicID
        departureCursor = nil
        catchUpRequestedIDs = []
        catchUpText = ""
    }

    func catchUp() {
        let cursor = departureCursor ?? document.arrivalTurnIDs.count
        let ids = Array(document.arrivalTurnIDs.dropFirst(cursor))
        guard !ids.isEmpty else { catchUpText = "No new committed speech."; return }
        let wanted = Set(ids)
        let evidence = document.turns.filter { wanted.contains($0.id) }
        // Raw evidence remains readable while optional generated catch-up is unavailable.
        catchUpText = (document.resolvedNotesLanguage == "uk" ? "Нові репліки мовою оригіналу:\n" : "New transcript evidence (original speech):\n") + evidence.map { "[\(Self.timestamp($0.start))] \($0.source == .mic ? "You" : "Remote"): \($0.text)" }.joined(separator: "\n")
        if ids.count <= 100 { catchUpRequestedIDs = ids; scheduleAnalysis() }
        else { status = "Catch-up shows original speech; automatic recap supports up to 100 turns." }
    }

    func addTopic(title: String, parentID: String? = nil) {
        guard !document.sessionID.isEmpty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard parentID == nil || document.topics.contains(where: { $0.id == parentID }) else { error = "Choose an existing parent topic."; return }
        let id = UUID().uuidString
        document.topics.append(ConversationTopic(id: id, parentID: parentID, title: title, manualTitle: true, manualParent: true))
        selectTopic(id)
        persist()
    }

    func renameTopic(_ id: String, title: String) {
        guard let index = document.topics.firstIndex(where: { $0.id == id }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        document.topics[index].title = title
        document.topics[index].manualTitle = true
        persist()
    }

    func pinTopic(_ id: String) {
        guard let index = document.topics.firstIndex(where: { $0.id == id }) else { return }
        document.topics[index].pinned.toggle()
        persist()
    }

    func moveTopic(_ id: String, parentID: String?) {
        guard let index = document.topics.firstIndex(where: { $0.id == id }) else { return }
        var candidate = document
        candidate.topics[index].parentID = parentID
        candidate.topics[index].manualParent = true
        do { try Self.validate(candidate); document = candidate; error = nil; persist() }
        catch { self.error = error.localizedDescription }
    }

    func mergeTopic(_ sourceID: String, into targetID: String) {
        guard sourceID != targetID, let source = document.topics.first(where: { $0.id == sourceID }), document.topics.contains(where: { $0.id == targetID }) else { return }
        var parent = document.topics.first { $0.id == targetID }?.parentID
        while let id = parent {
            guard id != sourceID else { error = "Cannot merge a parent into its descendant. Move the target first."; return }
            parent = document.topics.first { $0.id == id }?.parentID
        }
        var candidate = document
        candidate.topics.removeAll { $0.id == sourceID }
        guard let target = candidate.topics.firstIndex(where: { $0.id == targetID }) else { return }
        candidate.topics[target].turnIDs = Self.unique(candidate.topics[target].turnIDs + source.turnIDs)
        candidate.topics[target].pinned = candidate.topics[target].pinned || source.pinned
        candidate.topics[target].manualParent = true
        candidate.topics[target].manualTitle = true
        candidate.topics[target].isUnassigned = candidate.topics[target].isUnassigned && source.isUnassigned
        for var memo in source.memos {
            if candidate.topics[target].memos.contains(where: { $0.id == memo.id }) { memo.id = UUID().uuidString }
            candidate.topics[target].memos.append(memo)
        }
        if !source.summary.isEmpty, source.summary != candidate.topics[target].summary {
            candidate.topics[target].memos.append(LiveMemo(id: UUID().uuidString, kind: .note, text: source.summary, manual: true, turnIDs: source.turnIDs))
        }
        for index in candidate.topics.indices where candidate.topics[index].parentID == sourceID { candidate.topics[index].parentID = targetID; candidate.topics[index].manualParent = true }
        candidate.mergedTopicIDs[sourceID] = targetID
        for (alias, destination) in candidate.mergedTopicIDs where destination == sourceID { candidate.mergedTopicIDs[alias] = targetID }
        if candidate.currentTopicID == sourceID { candidate.currentTopicID = targetID }
        rebuildVisits(in: &candidate)
        do {
            try Self.validate(candidate)
            document = candidate
            if selectedTopicID == sourceID { selectedTopicID = targetID }
            error = nil
            persist()
        } catch { self.error = error.localizedDescription }
    }

    func editMemo(topicID: String, memoID: String, text: String) {
        guard let topic = document.topics.firstIndex(where: { $0.id == topicID }), let memo = document.topics[topic].memos.firstIndex(where: { $0.id == memoID }) else { return }
        document.topics[topic].memos[memo].text = text
        document.topics[topic].memos[memo].manual = true
        persist()
    }

    func pinMemo(topicID: String, memoID: String) {
        guard let topic = document.topics.firstIndex(where: { $0.id == topicID }), let memo = document.topics[topic].memos.firstIndex(where: { $0.id == memoID }) else { return }
        document.topics[topic].memos[memo].pinned.toggle()
        persist()
    }

    func end() {
        guard !document.sessionID.isEmpty else { return }
        document.isRecording = false
        partials = [:]
        status = analysisTask == nil ? "Live map saved" : "Recording stopped; automatic notes pending"
        persist()
    }

    func load(audioPath: String) throws {
        guard !document.isRecording else { throw ConversationMapError.invalid("Stop the active live meeting before opening another map.") }
        let url = Self.saveURL(audioPath: audioPath)
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 100_000_000 else { throw ConversationMapError.invalid("This live map exceeds the supported file size.") }
            let loaded = try JSONDecoder().decode(ConversationDocument.self, from: data)
            try Self.validate(loaded)
            guard URL(fileURLWithPath: loaded.audioPath).standardizedFileURL == URL(fileURLWithPath: audioPath).standardizedFileURL else { throw ConversationMapError.invalid("The saved map belongs to a different audio file.") }
            resetRuntime()
            document = loaded
            document.isRecording = false
            ownedSaveURL = url
            register(url)
            selectedTopicID = document.currentTopicID ?? document.topics.first?.id
            status = "Saved live map"
        } catch {
            self.error = "Could not open live map: \(error.localizedDescription)"
            throw error
        }
    }

    func exportMarkdown(to directory: URL) throws -> URL {
        guard !document.sessionID.isEmpty else { throw ConversationMapError.invalid("There is no live map to export.") }
        try Self.validate(document)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ConversationMapError.invalid("Choose an existing export folder.") }
        var lines = ["# \(Self.markdown(document.title))", "", "Source audio: \(Self.markdown(URL(fileURLWithPath: document.audioPath).lastPathComponent))", "", "Original live evidence is retained below; final processing does not replace it.", ""]
        func appendTopics(parentID: String?, depth: Int) {
            for topic in document.topics where topic.parentID == parentID {
                lines.append("\(String(repeating: "  ", count: depth))- **\(Self.markdown(topic.title))**\(topic.pinned ? " (pinned)" : "")")
                if !topic.summary.isEmpty { lines.append("\(String(repeating: "  ", count: depth + 1))\(Self.markdown(topic.summary))") }
                for memo in topic.memos {
                    lines.append("\(String(repeating: "  ", count: depth + 1))- [\(memo.kind.rawValue)\(memo.manual ? "; manual" : "; suggestion")\(memo.pinned ? "; pinned" : "")] \(Self.markdown(memo.text))")
                    if !memo.turnIDs.isEmpty { lines.append("\(String(repeating: "  ", count: depth + 2))Evidence: \(memo.turnIDs.map(Self.markdown).joined(separator: ", "))") }
                }
                if !topic.visits.isEmpty { lines.append("\(String(repeating: "  ", count: depth + 1))Visits: \(topic.visits.map { Self.timestamp($0.start) + "–" + Self.timestamp($0.end) }.joined(separator: ", "))") }
                appendTopics(parentID: topic.id, depth: depth + 1)
            }
        }
        appendTopics(parentID: nil, depth: 0)
        if !document.warnings.isEmpty { lines += ["", "## Recording warnings", ""] + document.warnings.map { "- " + Self.markdown($0) } }
        lines += ["", "## Original live transcript", ""]
        for turn in document.turns { lines.append("- [\(Self.timestamp(turn.start))–\(Self.timestamp(turn.end))] **\(turn.source == .mic ? "You" : "Remote")** (\(Self.markdown(turn.id))): \(Self.markdown(turn.text))") }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let basename = String(document.title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "-" }.prefix(100))
        let name = basename.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        for suffix in 0..<1000 {
            let url = directory.appendingPathComponent("\(name.isEmpty ? "Meeting" : name)-live\(suffix == 0 ? "" : "-\(suffix + 1)").md")
            do { try Self.writeNew(data, to: url); return url }
            catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        throw ConversationMapError.invalid("No unused Markdown export filename was available.")
    }

    private func resetRuntime() {
        analysisTask?.cancel()
        analysisTask = nil
        generation = UUID()
        pendingTurnIDs = []
        catchUpRequestedIDs = []
        departureCursor = nil
        selectedTopicID = nil
        followsLive = true
        catchUpText = ""
        error = nil
        partials = [:]
        configuration = nil
    }

    private func ensureDiscussion() -> Int {
        if let index = document.topics.firstIndex(where: { $0.isUnassigned }) { return index }
        // A merged bucket gets a fresh identity so old aliases cannot revive it.
        let id = document.mergedTopicIDs["discussion"] == nil ? "discussion" : "discussion-" + UUID().uuidString
        document.topics.append(ConversationTopic(id: id, title: document.resolvedNotesLanguage == "uk" ? "Обговорення" : "Discussion", isUnassigned: true))
        return document.topics.count - 1
    }

    private func configurationProblem(_ configuration: LiveNotesConfiguration) -> String? {
        if configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Automatic notes need a configured provider key. Transcript and manual notes remain available." }
        if let listed = configuration.listedModelIDs, !listed.contains(configuration.model) {
            return "\(configuration.model) is no longer offered by OpenRouter. Choose another live notes model in Settings."
        }
        if configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Automatic notes need an explicitly selected model. Transcript and manual notes remain available." }
        if !["https", "http"].contains(configuration.baseURL.scheme ?? "") || configuration.baseURL.host == nil || configuration.baseURL.user != nil || configuration.baseURL.password != nil || configuration.baseURL.query != nil || configuration.baseURL.fragment != nil { return "Automatic notes need a valid provider base URL without embedded credentials or query parameters." }
        return nil
    }

    private func scheduleAnalysis() {
        guard let configuration, configuration.enabled, configurationProblem(configuration) == nil else { return }
        guard document.resolvedNotesLanguage != nil else { status = "Choose notes language; waiting for detected speech language"; return }
        guard analysisTask == nil, !pendingTurnIDs.isEmpty || !catchUpRequestedIDs.isEmpty else { return }
        let token = generation
        analysisTask = Task { [weak self] in
            guard let delay = self?.coalescingDelay else { return }
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.runAnalysis(generation: token)
        }
    }

    private func runAnalysis(generation token: UUID) async {
        guard let configuration else { return }
        while !Task.isCancelled, token == generation, !pendingTurnIDs.isEmpty || !catchUpRequestedIDs.isEmpty {
            let pending = Array(pendingTurnIDs.prefix(100))
            let ids = Self.unique(pending + catchUpRequestedIDs).prefix(100)
            let allowed = Set(ids)
            let turns = document.turns.filter { allowed.contains($0.id) }
            let catchIDs = Set(catchUpRequestedIDs).isSubset(of: allowed) ? catchUpRequestedIDs : []
            status = "Updating automatic notes (\(document.resolvedNotesLanguage ?? ""))"
            do {
                let update = try await topicService.analyze(document: document, turns: turns, catchUpIDs: catchIDs, configuration: configuration,
                                                            onUsage: { [weak self] usage in await self?.recordUsage(usage, generation: token) })
                guard !Task.isCancelled, token == generation else { return }
                guard Set(pending).isSubset(of: Set(update.topics.flatMap(\.turnIDs))) else { throw ConversationMapError.invalid("Automatic notes omitted pending source evidence. The unprocessed turns remain available.") }
                try apply(update)
                document.mappedTurnIDs = Self.unique(document.mappedTurnIDs + pending)
                pendingTurnIDs.removeAll { pending.contains($0) }
                if let catchUp = update.catchUp, Set(catchIDs) == Set(catchUpRequestedIDs), !followsLive { catchUpText = catchUp.text }
                catchUpRequestedIDs.removeAll { catchIDs.contains($0) }
                error = nil
                status = document.isRecording ? "Live notes (\(document.resolvedNotesLanguage ?? ""))" : "Live map saved"
                persist()
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                self.error = error.localizedDescription
                status = "Automatic notes unavailable; transcript and manual notes continue"
                break // No automatic retry loop or duplicate provider charge after a failure.
            }
        }
        if token == generation { analysisTask = nil }
    }

    /// Counted as soon as the provider answers, so charged-but-rejected responses count too.
    private func recordUsage(_ usage: LiveNotesUsage, generation token: UUID) {
        guard token == generation else { return }
        document.liveNotesUsage = (document.liveNotesUsage ?? LiveNotesUsage()).adding(usage)
    }

    private func apply(_ update: ConversationTopicUpdate) throws {
        var candidate = document
        var canonicalIDs = Set<String>()
        for proposed in update.topics {
            let id = candidate.mergedTopicIDs[proposed.id] ?? proposed.id
            guard canonicalIDs.insert(id).inserted else { throw ConversationMapError.invalid("Automatic notes returned duplicate merged topics.") }
            let parent = proposed.parentID.map { candidate.mergedTopicIDs[$0] ?? $0 }
            if let index = candidate.topics.firstIndex(where: { $0.id == id }) {
                if !candidate.topics[index].pinned {
                    if !candidate.topics[index].manualTitle { candidate.topics[index].title = proposed.title }
                    if !candidate.topics[index].manualParent { candidate.topics[index].parentID = parent }
                    candidate.topics[index].summary = proposed.summary
                }
                candidate.topics[index].turnIDs = Self.unique(candidate.topics[index].turnIDs + proposed.turnIDs)
                for memo in proposed.memos {
                    if let memoIndex = candidate.topics[index].memos.firstIndex(where: { $0.id == memo.id }) {
                        let existing = candidate.topics[index].memos[memoIndex]
                        if candidate.topics[index].pinned || existing.manual || existing.pinned {
                            if (existing.text != memo.text || existing.kind != memo.kind), !candidate.topics[index].memos.contains(where: { $0.suggestedRevisionOf == memo.id && $0.text == memo.text && $0.kind == memo.kind && Set($0.turnIDs) == Set(memo.turnIDs) }) {
                                candidate.topics[index].memos.append(LiveMemo(id: UUID().uuidString, kind: memo.kind, text: memo.text, turnIDs: memo.turnIDs, suggestedRevisionOf: memo.id))
                            }
                        } else {
                            candidate.topics[index].memos[memoIndex].text = memo.text
                            candidate.topics[index].memos[memoIndex].kind = memo.kind
                            candidate.topics[index].memos[memoIndex].turnIDs = Self.unique(existing.turnIDs + memo.turnIDs)
                        }
                    } else { candidate.topics[index].memos.append(LiveMemo(id: memo.id, kind: memo.kind, text: memo.text, turnIDs: memo.turnIDs)) }
                }
            } else {
                candidate.topics.append(ConversationTopic(id: id, parentID: parent, title: proposed.title, summary: proposed.summary, memos: proposed.memos.map { LiveMemo(id: $0.id, kind: $0.kind, text: $0.text, turnIDs: $0.turnIDs) }, turnIDs: proposed.turnIDs))
            }
        }
        let assigned = Set(candidate.topics.filter { !$0.isUnassigned }.flatMap(\.turnIDs))
        for index in candidate.topics.indices where candidate.topics[index].isUnassigned { candidate.topics[index].turnIDs.removeAll { assigned.contains($0) } }
        if let current = update.currentTopicID {
            let canonical = candidate.mergedTopicIDs[current] ?? current
            guard candidate.topics.contains(where: { $0.id == canonical }) else { throw ConversationMapError.invalid("Automatic notes returned an unknown live topic.") }
        }
        if let latest = candidate.turns.last {
            candidate.currentTopicID = candidate.topics.last(where: { $0.turnIDs.contains(latest.id) })?.id ?? candidate.currentTopicID
        }
        rebuildVisits(in: &candidate)
        try Self.validate(candidate)
        document = candidate
        if followsLive { selectedTopicID = document.currentTopicID }
    }

    private func rebuildVisits(in document: inout ConversationDocument) {
        for index in document.topics.indices {
            let ids = Set(document.topics[index].turnIDs)
            var visits: [TopicVisit] = []
            var previousBelonged = false
            for turn in document.turns {
                let belongs = ids.contains(turn.id)
                if belongs {
                    if previousBelonged, let last = visits.indices.last {
                        visits[last].end = max(visits[last].end, turn.end)
                        visits[last].turnIDs.append(turn.id)
                    } else { visits.append(TopicVisit(start: turn.start, end: turn.end, turnIDs: [turn.id])) }
                }
                previousBelonged = belongs
            }
            document.topics[index].visits = visits
            document.topics[index].turnIDs = document.turns.filter { ids.contains($0.id) }.map(\.id)
        }
    }

    private func persist() {
        guard let url = ownedSaveURL else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; try encoder.encode(document).write(to: url, options: .atomic) }
        catch { self.error = "Live map could not be saved: \(error.localizedDescription)"; return }
        // A saved map edited in any window; the meeting being recorded is reported (throttled)
        // by the app's live watcher instead.
        if !document.isRecording { ModelFileEvents.notify(.liveMap(sessionID: document.sessionID)) }
    }

    private static func validate(_ document: ConversationDocument) throws {
        guard document.schemaVersion == 1 else { throw ConversationMapError.invalid("Unsupported live map schema version. The existing map was not changed.") }
        guard !document.sessionID.isEmpty, document.turns.allSatisfy(validTurn), Set(document.turns.map(\.id)).count == document.turns.count else { throw ConversationMapError.invalid("The live map contains invalid or duplicate turns.") }
        let turnIDs = Set(document.turns.map(\.id))
        guard Set(document.mappedTurnIDs).isSubset(of: turnIDs), Set(document.mappedTurnIDs).count == document.mappedTurnIDs.count else { throw ConversationMapError.invalid("The saved map has an invalid analysis watermark.") }
        let topicIDs = Set(document.topics.map(\.id))
        guard topicIDs.count == document.topics.count, document.topics.allSatisfy({ !$0.id.isEmpty }), Set(document.arrivalTurnIDs) == turnIDs, document.arrivalTurnIDs.count == turnIDs.count else { throw ConversationMapError.invalid("The live map contains invalid topic IDs or an invalid arrival timeline.") }
        if let current = document.currentTopicID, !topicIDs.contains(current) { throw ConversationMapError.invalid("The live map points to an unknown current topic.") }
        for topic in document.topics {
            guard Set(topic.turnIDs).isSubset(of: turnIDs), Set(topic.turnIDs).count == topic.turnIDs.count else { throw ConversationMapError.invalid("A topic references missing or duplicate evidence.") }
            guard Set(topic.memos.map(\.id)).count == topic.memos.count else { throw ConversationMapError.invalid("A topic contains duplicate memo IDs.") }
            for memo in topic.memos where !Set(memo.turnIDs).isSubset(of: turnIDs) { throw ConversationMapError.invalid("A memo references missing evidence.") }
            for visit in topic.visits {
                guard visit.start.isFinite, visit.end.isFinite, visit.start >= 0, visit.end >= visit.start, visit.end <= maxOffsetSeconds, !visit.turnIDs.isEmpty, Set(visit.turnIDs).isSubset(of: Set(topic.turnIDs)) else { throw ConversationMapError.invalid("A topic visit contains invalid evidence or offsets.") }
            }
            var seen: Set<String> = [topic.id]
            var parent = topic.parentID
            while let id = parent {
                guard topicIDs.contains(id), seen.insert(id).inserted else { throw ConversationMapError.invalid("A topic move would create a cycle or reference a missing parent.") }
                parent = document.topics.first { $0.id == id }?.parentID
            }
        }
        for (alias, target) in document.mergedTopicIDs where topicIDs.contains(alias) || !topicIDs.contains(target) { throw ConversationMapError.invalid("The live map contains an invalid merged topic alias.") }
    }

    private static func validTurn(_ turn: LiveTurn) -> Bool { !turn.id.isEmpty && turn.id.count <= 128 && turn.start.isFinite && turn.end.isFinite && turn.start >= 0 && turn.end >= turn.start && turn.end <= maxOffsetSeconds && !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && turn.text.count <= 20_000 }
    /// Notes languages the live map accepts (codes as Whisper reports them).
    nonisolated static let knownLanguages: Set<String> = ["en", "uk", "ru", "pl", "de", "fr", "es", "it", "pt", "nl", "cs", "sv", "tr", "ja", "ko", "zh", "ar", "hi"]
    private static func resolvedLanguage(_ value: String) -> String? {
        let code = value.lowercased()
        return knownLanguages.contains(code) ? code : nil
    }
    private static func unique(_ ids: [String]) -> [String] { var seen = Set<String>(); return ids.filter { seen.insert($0).inserted } }
    private static func writeNew(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".live-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    private static func saveURL(audioPath: String) -> URL {
        let audio = URL(fileURLWithPath: audioPath)
        return audio.deletingLastPathComponent().appendingPathComponent(audio.deletingPathExtension().lastPathComponent + "_live.json")
    }
    /// Total: never traps, even for NaN/infinite/huge data from a damaged file.
    static func timestamp(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(min(max(0, seconds), maxOffsetSeconds)) : 0
        return value >= 3600 ? String(format: "%02ld:%02ld:%02ld", value / 3600, value / 60 % 60, value % 60) : String(format: "%02ld:%02ld", value / 60, value % 60)
    }
    private static func markdown(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: "\n  ")
    }
}
