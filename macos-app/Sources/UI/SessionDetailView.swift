import SwiftUI
import OSLog

/// Full session detail view showing metadata, the transcript with playback, the note,
/// and action buttons for transcription and export.
@available(macOS 14.2, *)
struct SessionDetailView: View {
    @Environment(AppModel.self) private var appModel
    let session: Session
    /// Transcript position to open at (from a search hit); the player is positioned, not started.
    var focusTime: Double?

    @Environment(\.dismiss) private var dismiss

    @State private var editableTitle: String = ""
    @State private var isTranscribing = false
    @State private var transcriptionError: String?
    @State private var saveMessage: String?
    @State private var showDeleteConfirm = false
    /// Freshly-reloaded copy of the session, so transcript paths/status are
    /// current after transcription (the passed-in struct can be stale).
    @State private var liveSession: Session?
    /// Decoded conversation analysis sidecar for the insights panel.
    @State private var analysis: ConversationAnalysis?
    @State private var savedLiveModel: LiveMeetingModel?
    @State private var showLiveMap = false
    @State private var transcriptLines: [TranscriptLine] = []
    /// Bumped when the transcript changes (e.g. Re-process) so the player reloads.
    @State private var transcriptRevision = 0
    @State private var transcriptLoadError: String?
    @State private var noteText: String?
    @State private var speakerNames = SpeakerNames()

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "SessionDetail"
    )

    /// The most up-to-date session record available.
    private var current: Session { liveSession ?? session }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                metadataSection
                audioSection
                transcriptSection
                markdownSection
                insightsSection
                if hasLiveMap {
                    Button("Open live conversation map") { openLiveMap() }
                        .buttonStyle(.bordered)
                }
                warningSection
                errorSection
                actionButtons
            }
            .padding()
        }
        .frame(minWidth: 380)
        .navigationTitle(session.title)
        .confirmationDialog(
            "Delete this session?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Session and Files", role: .destructive) {
                appModel.sessionManager.deleteSession(id: session.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The audio, transcript, note, and analysis files will be permanently removed.")
        }
        .sheet(isPresented: $showLiveMap) {
            if let savedLiveModel {
                LiveMeetingWorkspace(model: savedLiveModel,
                    processingStatus: savedLiveModel.document.isRecording ? appModel.liveMeeting.status : "Saved live map",
                    microphoneEnabled: savedLiveModel.document.isRecording ? appModel.liveMicrophoneEnabled :
                        FileManager.default.fileExists(atPath: URL(fileURLWithPath: session.audioPath).deletingPathExtension().path + "_mic.wav"))
            }
        }
        .onAppear {
            editableTitle = session.title
            reload()
        }
    }

    private func reload() {
        liveSession = appModel.sessionManager.session(id: session.id)
        analysis = current.analysisPath.flatMap(ConversationAnalysis.load(fromPath:))
        var lines: [TranscriptLine] = []
        transcriptLoadError = nil
        if let path = current.transcriptRawPath, FileManager.default.fileExists(atPath: path) {
            do { lines = try TranscriptDocument.load(path: path) } catch {
                transcriptLoadError = "The transcript file could not be read: \(error.localizedDescription)"
            }
        }
        if lines != transcriptLines {
            transcriptLines = lines
            transcriptRevision += 1
        }
        noteText = current.transcriptMarkdownPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        do { speakerNames = try SpeakerNames.load(audioPath: current.audioPath) } catch {
            transcriptionError = "Speaker names could not be read: \(error.localizedDescription)"
        }
    }

    private func renameSpeaker(_ label: String, to name: String) {
        let updated = speakerNames.renamed(label, to: name)
        do {
            try updated.save(audioPath: current.audioPath)
            speakerNames = updated
        } catch {
            transcriptionError = "Could not save the speaker name: \(error.localizedDescription)"
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $editableTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textFieldStyle(.plain)
                StatusBadge(status: session.status)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var metadataSection: some View {
        GroupBox("Details") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Type")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { RecordingType(rawValue: current.recordingType) ?? .callMeeting },
                        set: { newType in
                            // id is the stable original identity; `current` is read-only here.
                            appModel.sessionManager.updateRecordingType(
                                id: session.id,
                                recordingType: newType.rawValue
                            )
                            reload()
                        }
                    )) {
                        ForEach(RecordingType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                GridRow {
                    Text("Language")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { SpokenLanguage(rawValue: current.language) ?? .auto },
                        set: { newLang in
                            appModel.sessionManager.updateLanguage(
                                id: session.id,
                                language: newLang.rawValue
                            )
                            reload()
                        }
                    )) {
                        ForEach(SpokenLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                GridRow {
                    Text("Notes language")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { SpokenLanguage(rawValue: current.notesLanguage) ?? .auto },
                        set: { newLang in
                            appModel.sessionManager.updateNotesLanguage(
                                id: session.id,
                                language: newLang.rawValue
                            )
                            reload()
                        }
                    )) {
                        ForEach(SpokenLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                detailRow("Source App", session.sourceApp)
                detailRow("Started", session.startedAt.formatted(date: .abbreviated, time: .standard))
                if let endedAt = session.endedAt {
                    detailRow("Ended", endedAt.formatted(date: .abbreviated, time: .standard))
                }
                if let duration = session.durationSec {
                    detailRow("Duration", formattedDuration(duration))
                }
                if current.costTranscription != nil || current.costProcessing != nil {
                    detailRow(
                        "Cost",
                        "Transcription \(CostFormat.usd(current.costTranscription)) · "
                        + "Processing \(CostFormat.usd(current.costProcessing)) · "
                        + "Total \(CostFormat.usd(CostFormat.total(current.costTranscription, current.costProcessing)))"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        GroupBox("Audio") {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                Text(session.audioPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Open in Finder") {
                    NSWorkspace.shared.selectFile(
                        session.audioPath,
                        inFileViewerRootedAtPath: ""
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if !transcriptLines.isEmpty {
            GroupBox("Transcript") {
                TranscriptPlayerView(lines: transcriptLines, names: speakerNames,
                                     audioPath: current.audioPath, focusTime: focusTime,
                                     playbackBlocked: appModel.playbackBlocked,
                                     onRename: renameSpeaker)
                    .id(transcriptRevision)
            }
        } else if let transcriptLoadError {
            GroupBox("Transcript") {
                Label(transcriptLoadError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var markdownSection: some View {
        if let noteText, let mdPath = current.transcriptMarkdownPath {
            GroupBox("Markdown Note") {
                VStack(alignment: .leading, spacing: 8) {
                    NoteTextView(text: speakerNames.apply(to: noteText))
                    Button("Open Markdown") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: mdPath))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var insightsSection: some View {
        if let analysis, analysis.hasContent {
            GroupBox("Conversation Insights") {
                ConversationInsightsView(analysis: analysis, names: speakerNames)
            }
        }
    }

    @ViewBuilder
    private var warningSection: some View {
        if let warning = current.warningMessage, !warning.isEmpty {
            GroupBox("Warnings") {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = transcriptionError {
            GroupBox("Error") {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let saveMessage {
            Label(saveMessage, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        let hasMarkdown = current.transcriptMarkdownPath
            .map { FileManager.default.fileExists(atPath: $0) } ?? false

        HStack(spacing: 12) {
            if isTranscribing {
                ProgressView(value: appModel.pythonBridge.progress)
                    .progressViewStyle(.linear)
            }

            Spacer()

            if current.status == "completed" {
                transcribeButton(label: "Transcribe")
            }
            if current.status == "transcribed" {
                transcribeButton(label: "Re-process")
            }
            // Failed / interrupted / dead-`transcribing` sessions also need a
            // way out — until now they were stuck without any action button.
            if ["error", "failed", "interrupted"].contains(current.status) {
                transcribeButton(label: "Retry")
            }

            if hasMarkdown {
                Button("Save to Vault") { saveToConfiguredDirectory() }
                    .buttonStyle(.borderedProminent)
            }

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(isTranscribing || appModel.state == .transcribing || current.status == "recording")

            Menu("Export") {
                Button("Markdown (.md)") { exportFile(extension: "md") }
                Button("Plain Text (.txt)") { exportFile(extension: "txt") }
                Button("JSON (.json)") { exportFile(extension: "json") }
            }
            .menuStyle(.borderedButton)
            .controlSize(.regular)
            .disabled(!hasMarkdown)
        }
        if let reason = transcribeBlockReason, ["completed", "transcribed", "error", "failed", "interrupted"].contains(current.status) {
            Text("\(reason) This session uses cloud transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Actions

    private var hasLiveMap: Bool {
        appModel.liveMeeting.model.document.sessionID == session.id || FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: session.audioPath).deletingPathExtension().path + "_live.json")
    }

    private func openLiveMap() {
        do {
            // One shared writer per saved map: the active/stopped session model, or a single
            // loaded instance reused by every sheet, never a second mutable copy.
            let active = appModel.liveMeeting.model
            savedLiveModel = active.document.sessionID == session.id
                ? active : try LiveMeetingModel.opened(audioPath: session.audioPath)
            showLiveMap = true
        } catch { transcriptionError = "Could not open live map: \(error.localizedDescription)" }
    }

    private func transcribeButton(label: String) -> some View {
        Button(label) {
            Task { await transcribe() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isTranscribing || appModel.state == .transcribing || transcribeBlockReason != nil)
    }

    /// Cloud sessions cannot be (re)transcribed offline; local Whisper can.
    private var transcribeBlockReason: String? {
        NetworkPolicy.blockReason(engine: JobRequest.transcribe(session: current, settings: appModel.settingsManager).engine,
                                  isOnline: appModel.connectivity.isOnline)
    }

    private func transcribe() async {
        isTranscribing = true
        transcriptionError = nil
        saveMessage = nil

        // Use `current` (DB-fresh) so Re-process picks up an edited recording type.
        await appModel.transcribeSession(current)

        if appModel.state == .error {
            transcriptionError = appModel.lastError
        }

        isTranscribing = false
        reload()
        Self.logger.info("Transcription flow completed for session \(session.id)")
    }

    private func exportFile(extension ext: String) {
        let format = SessionExport.Format(rawValue: ext) ?? .md
        guard let source = SessionExport.sourcePath(for: format, session: current),
              FileManager.default.fileExists(atPath: source) else {
            saveMessage = nil
            transcriptionError = "Nothing to export yet — transcribe first."
            return
        }

        let data: Data
        do {
            data = try SessionExport.data(from: source, format: format, names: speakerNames)
        } catch {
            transcriptionError = "Export failed: \(error.localizedDescription)"
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeFileName(current.title)).\(ext)"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // The panel already confirmed any replacement; write atomically so a failure keeps the old file.
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            transcriptionError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Copies the markdown note into the configured Obsidian vault (or the
    /// output directory if no vault is set), creating the dated subfolder.
    private func saveToConfiguredDirectory() {
        transcriptionError = nil
        saveMessage = nil

        guard let mdPath = current.transcriptMarkdownPath,
              FileManager.default.fileExists(atPath: mdPath) else {
            transcriptionError = "No markdown note to save — transcribe first."
            return
        }

        let settings = appModel.settingsManager
        let destDir = SessionExport.vaultDirectory(
            startedAt: current.startedAt,
            vault: settings.obsidianExportDirectory,
            folderPattern: settings.obsidianFolderPattern,
            outputDirectory: settings.outputDirectory
        )

        do {
            let destURL = try SessionExport.saveNote(markdownPath: mdPath, names: speakerNames,
                                                     directory: destDir, title: current.title,
                                                     sessionID: current.id)
            saveMessage = "Saved to \(destURL.path)"
            Self.logger.info("Saved note to \(destURL.path)")
        } catch {
            transcriptionError = "Save failed: \(error.localizedDescription)"
            Self.logger.error("Save to vault failed: \(error)")
        }
    }

    private func safeFileName(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
    }

    // MARK: - Helpers

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
    }
}
