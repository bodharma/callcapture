import Foundation

/// A live map plus the runtime state the web live view shows beside it.
struct LiveView: Sendable, Equatable {
    var document: ConversationDocument
    /// True while this map's meeting is being recorded.
    var live: Bool
    var status: String
    var processingStatus: String
    var error: String?
    var followsLive: Bool
    var selectedTopicID: String?
    var catchUpText: String
    /// Partial speech by channel (`mic`, `system`).
    var partials: [String: String]
    var microphoneEnabled: Bool
    /// The local speech worker is running.
    var speechRunning: Bool

    /// A saved map: nothing runs and the page keeps its own selection.
    static func saved(_ document: ConversationDocument, microphoneEnabled: Bool) -> LiveView {
        LiveView(
            document: document, live: false, status: "Saved live map", processingStatus: "Saved live map",
            error: nil, followsLive: true, selectedTopicID: nil, catchUpText: "", partials: [:],
            microphoneEnabled: microphoneEnabled, speechRunning: false)
    }
}

/// `GET /api/live` and `GET /api/sessions/:id/live`. Everything the SwiftUI live
/// workspace shows, without the audio path or the model's internal bookkeeping.
struct LiveViewDTO: Encodable {
    /// The notes languages offered while Auto is unresolved (as the old SwiftUI workspace did).
    static let notesLanguageChoices = ["en", "uk", "pl", "de", "fr", "es"]

    let active: Bool
    let sessionID: String
    let title: String
    let audioFileName: String
    let status: String
    let processingStatus: String
    let error: String?
    let followsLive: Bool
    let selectedTopicID: String?
    let currentTopicID: String?
    let catchUpText: String
    let partials: [String: String]
    let microphoneEnabled: Bool
    let speechRunning: Bool
    let mappedThroughSeconds: Double?
    let speechLanguage: String
    let notesLanguage: String
    let resolvedNotesLanguage: String?
    let canChooseNotesLanguage: Bool
    let notesLanguageChoices: [String]
    let usage: LiveNotesUsage?
    let warnings: [String]
    let turns: [LiveTurn]
    let topics: [ConversationTopic]
    let offlineMessage: String

    init(_ view: LiveView) {
        let document = view.document
        let mapped = Set(document.mappedTurnIDs)
        active = view.live
        sessionID = document.sessionID
        title = document.title
        audioFileName = URL(fileURLWithPath: document.audioPath).lastPathComponent
        status = view.status
        processingStatus = view.processingStatus
        error = view.error
        followsLive = view.followsLive
        selectedTopicID = view.selectedTopicID
        currentTopicID = document.currentTopicID
        catchUpText = view.catchUpText
        partials = view.partials
        microphoneEnabled = view.microphoneEnabled
        speechRunning = view.speechRunning
        mappedThroughSeconds = document.turns.filter { mapped.contains($0.id) }.map(\.end).max()
        speechLanguage = document.speechLanguage
        notesLanguage = document.notesLanguage
        resolvedNotesLanguage = document.resolvedNotesLanguage
        canChooseNotesLanguage = document.notesLanguage == "auto" && document.resolvedNotesLanguage == nil
        notesLanguageChoices = Self.notesLanguageChoices
        usage = document.liveNotesUsage
        warnings = document.warnings
        turns = document.turns
        topics = document.topics
        offlineMessage = ConversationTopicService.offlineMessage
    }
}

/// `GET /api/live` with no meeting being recorded; `lastSessionID` names the map of
/// the meeting that ended last, which opens at `/sessions/<id>/live`.
struct InactiveLiveDTO: Encodable {
    let active = false
    let lastSessionID: String?
}
