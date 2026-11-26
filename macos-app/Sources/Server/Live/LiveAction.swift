import Foundation

/// Which live map an action edits: the meeting being recorded, or a session's saved map.
enum LiveTarget: Equatable, Sendable {
    case current
    case session(String)
}

/// One web live action; each case maps 1:1 to a `LiveMeetingModel` method, the same
/// one the SwiftUI live workspace calls.
enum LiveAction: Equatable, Sendable {
    /// `addManualNote`; with `topicID`, `selectTopic` first (saved maps keep the
    /// selection in the page, not in the model).
    case addNote(text: String, kind: LiveMemoKind, topicID: String?)
    case catchUp
    case backToLive
    case setNotesLanguage(String)
    case addTopic(title: String, parentID: String?)
    case selectTopic(String)
    case renameTopic(String, title: String)
    case moveTopic(String, parentID: String?)
    case mergeTopic(String, into: String)
    /// `pinTopic` toggles; it runs only when the topic isn't already in that state, so
    /// two hosts pinning at once can't undo each other.
    case pinTopic(String, pinned: Bool)
    case editMemo(topicID: String, memoID: String, text: String)
    case pinMemo(topicID: String, memoID: String, pinned: Bool)
    /// `exportMarkdown(to:)` into a folder the user chooses.
    case export
}

enum LiveActionError: Error, Equatable {
    /// `.current` while no meeting is being recorded.
    case noLiveMeeting
    case notFound
    /// The model would refuse the change; the message says why.
    case refused(String)
}

enum LiveActionOutcome: Equatable, Sendable {
    case done
    /// The written Markdown file, or nil when the folder chooser was cancelled.
    case exported(String?)
}

extension LiveAction {
    /// Why the model would ignore or refuse this action, checked before it runs: unknown
    /// topics and memos are `.notFound`; cycles, self-merges and a notes language that
    /// can no longer change are `.refused`.
    func problem(in document: ConversationDocument) -> LiveActionError? {
        let topics = Dictionary(document.topics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func missing(_ ids: String?...) -> Bool { ids.compactMap { $0 }.contains { topics[$0] == nil } }
        /// True when `candidate` is `ancestor` or sits somewhere under it.
        func isWithin(_ candidate: String, _ ancestor: String) -> Bool {
            var seen = Set<String>()
            var current: String? = candidate
            while let id = current, seen.insert(id).inserted {
                if id == ancestor { return true }
                current = topics[id]?.parentID
            }
            return false
        }
        switch self {
        case .catchUp, .backToLive, .export:
            return nil
        case .addNote(_, _, let topicID):
            return missing(topicID) ? .notFound : nil
        case .addTopic(_, let parentID):
            return missing(parentID) ? .notFound : nil
        case .selectTopic(let id), .renameTopic(let id, _), .pinTopic(let id, _):
            return missing(id) ? .notFound : nil
        case .setNotesLanguage(let code):
            guard document.notesLanguage == "auto", document.resolvedNotesLanguage == nil else {
                return .refused("The notes language is already set for this meeting.")
            }
            return LiveMeetingModel.knownLanguages.contains(code) ? nil : .refused("Choose a listed language.")
        case .moveTopic(let id, let parentID):
            if missing(id, parentID) { return .notFound }
            if let parentID, isWithin(parentID, id) {
                return .refused("A topic can't move under itself or one of its own subtopics.")
            }
            return nil
        case .mergeTopic(let id, let target):
            if missing(id, target) { return .notFound }
            if id == target { return .refused("Choose a different topic to merge into.") }
            if isWithin(target, id) { return .refused("Cannot merge a parent into its descendant. Move the target first.") }
            return nil
        case .editMemo(let topicID, let memoID, _), .pinMemo(let topicID, let memoID, _):
            guard let topic = topics[topicID], topic.memos.contains(where: { $0.id == memoID }) else {
                return .notFound
            }
            return nil
        }
    }

    /// Calls the matching model method. A refusal the model reports through `error`
    /// (it checks more than `problem(in:)` does) is thrown as `.refused`. `.export`
    /// needs a folder, so the backend handles it.
    @MainActor func apply(to model: LiveMeetingModel) throws {
        let errorBefore = model.error
        switch self {
        case .addNote(let text, let kind, let topicID):
            if let topicID, model.selectedTopicID != topicID { model.selectTopic(topicID) }
            model.addManualNote(text, kind: kind)
        case .catchUp: model.catchUp()
        case .backToLive: model.backToLive()
        case .setNotesLanguage(let code): model.setNotesLanguage(code)
        case .addTopic(let title, let parentID): model.addTopic(title: title, parentID: parentID)
        case .selectTopic(let id): model.selectTopic(id)
        case .renameTopic(let id, let title): model.renameTopic(id, title: title)
        case .moveTopic(let id, let parentID): model.moveTopic(id, parentID: parentID)
        case .mergeTopic(let id, let target): model.mergeTopic(id, into: target)
        case .pinTopic(let id, let pinned):
            if model.document.topics.first(where: { $0.id == id })?.pinned != pinned { model.pinTopic(id) }
        case .editMemo(let topicID, let memoID, let text): model.editMemo(topicID: topicID, memoID: memoID, text: text)
        case .pinMemo(let topicID, let memoID, let pinned):
            let memo = model.document.topics.first { $0.id == topicID }?.memos.first { $0.id == memoID }
            if memo?.pinned != pinned { model.pinMemo(topicID: topicID, memoID: memoID) }
        case .export:
            throw LiveActionError.refused("Export needs a folder; ask the app to choose one.")
        }
        if let error = model.error, error != errorBefore { throw LiveActionError.refused(error) }
    }
}
