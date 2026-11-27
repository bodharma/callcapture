import Foundation

/// Recording control and the live map for the web API. Every check and change happens
/// in one main-actor step, the same actor the menu and the SwiftUI live workspace use,
/// so the hosts can't interleave halfway through an action (last write wins).
@available(macOS 14.2, *)
extension AppModelBackend {
    func startRecording() async throws {
        let model = try requireModel()
        try await MainActor.run { _ = try model.beginRecordingTransition(.starting) }
    }

    func stopRecording() async throws {
        let model = try requireModel()
        try await MainActor.run { _ = try model.beginRecordingTransition(.stopping) }
    }

    func liveView(_ target: LiveTarget) async throws -> LiveView? {
        let model = try requireModel()
        var session: Session?
        if case .session(let id) = target { session = try await requireSession(id) }
        let (source, active) = await MainActor.run { () -> (LiveTargetSource?, LiveView?) in
            let source = LiveTargetPolicy.viewSource(target, activeSessionID: model.liveMeeting.model.document.sessionID)
            return (source, source == .active ? Self.currentView(model) : nil)
        }
        switch source {
        case nil: return nil
        case .active: return active
        case .saved:
            guard let session, let document = try SavedLiveMap.load(audioPath: session.audioPath) else {
                throw BackendError.notFound
            }
            return .saved(document, microphoneEnabled: Self.hasMicTrack(session))
        }
    }

    func performLive(_ action: LiveAction, on target: LiveTarget) async throws -> LiveActionOutcome {
        let model = try requireModel()
        let audioPath = try await savedAudioPath(target)
        if action == .export { return try await export(target, model: model, audioPath: audioPath) }
        try await MainActor.run {
            let live = try Self.liveModel(target, app: model, audioPath: audioPath)
            if let problem = action.problem(in: live.document) { throw problem }
            try action.apply(to: live)
        }
        return .done
    }

    /// Asks for a folder (NSOpenPanel, as the old live workspace's Export did), then writes the map.
    private func export(_ target: LiveTarget, model: AppModel, audioPath: String?) async throws -> LiveActionOutcome {
        // Fail before showing a panel when there is nothing to export.
        _ = try await MainActor.run { try Self.liveModel(target, app: model, audioPath: audioPath) }
        let folder = try await Task { @MainActor in
            try await FolderPicker.shared.choose(message: "Choose a folder for the live map.", startingAt: "")
        }.value
        guard let folder else { return .exported(nil) }
        let written = try await MainActor.run {
            try Self.liveModel(target, app: model, audioPath: audioPath)
                .exportMarkdown(to: URL(fileURLWithPath: folder, isDirectory: true))
        }
        return .exported(written.path)
    }

    /// The session's audio path for `.session` targets (`.notFound` for unknown ids).
    private func savedAudioPath(_ target: LiveTarget) async throws -> String? {
        guard case .session(let id) = target else { return nil }
        return try await requireSession(id).audioPath
    }

    /// The meeting being recorded, or one shared writer for a saved map: the active
    /// controller model when the session is the live one, else the instance the SwiftUI
    /// sheet may already hold (`LiveMeetingModel.opened`), never a second copy.
    @MainActor
    private static func liveModel(_ target: LiveTarget, app: AppModel, audioPath: String?) throws -> LiveMeetingModel {
        let active = app.liveMeeting.model
        let savedMapExists = audioPath.map { FileManager.default.fileExists(atPath: SavedLiveMap.path(audioPath: $0)) }
        let source = try LiveTargetPolicy.actionSource(
            target, activeSessionID: active.document.sessionID, activeIsRecording: active.document.isRecording,
            savedMapExists: savedMapExists ?? false)
        switch source {
        case .active: return active
        case .saved:
            guard let audioPath else { throw LiveActionError.notFound }
            return try LiveMeetingModel.opened(audioPath: audioPath)
        }
    }

    @MainActor
    private static func currentView(_ app: AppModel) -> LiveView {
        let controller = app.liveMeeting
        let live = controller.model
        var partials: [String: String] = [:]
        for (source, text) in live.partials where !text.isEmpty { partials[source.rawValue] = text }
        return LiveView(
            document: live.document, live: live.document.isRecording, status: live.status,
            processingStatus: controller.status, error: live.error, followsLive: live.followsLive,
            selectedTopicID: live.selectedTopicID, catchUpText: live.catchUpText, partials: partials,
            microphoneEnabled: app.liveMicrophoneEnabled, speechRunning: controller.isRunning)
    }

    /// Whether a saved map's recording kept a microphone stem.
    private static func hasMicTrack(_ session: Session) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: session.audioPath).deletingPathExtension().path + "_mic.wav")
    }
}
