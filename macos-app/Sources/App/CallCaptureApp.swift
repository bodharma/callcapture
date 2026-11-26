import SwiftUI
import CoreAudio
import OSLog

/// Application state representing the current recording lifecycle phase.
enum AppState: String, Sendable {
    case idle
    case recording
    case transcribing
    case error
}

/// Main application entry point. Renders as a menu bar extra with a popover.
@available(macOS 14.2, *)
@main
struct CallCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel

    init() {
        do {
            let database = try AppDatabase()
            _appModel = State(initialValue: AppModel(database: database))
        } catch {
            fatalError("Failed to open database: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(appModel)
        } label: {
            Image(systemName: appModel.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        Window("Sessions", id: "sessions") {
            SessionListView()
                .environment(appModel)
        }

        Window("Live Meeting", id: "live-meeting") {
            LiveMeetingWorkspace(model: appModel.liveMeeting.model,
                                 processingStatus: appModel.liveMeeting.status,
                                 microphoneEnabled: appModel.liveMicrophoneEnabled)
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
                .environment(appModel)
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(appModel)
        }
    }
}

/// Central application model holding shared state across the UI.
@available(macOS 14.2, *)
@Observable
final class AppModel {
    /// Process-wide reference used by `AppDelegate` to tear down audio and
    /// worker resources on quit/signal, where SwiftUI environment access is
    /// unavailable.
    @ObservationIgnored
    static weak var shared: AppModel?

    var state: AppState = .idle
    var lastError: String?
    var lastSessionTitle: String?
    var lastSessionDate: Date?
    var lastSessionDuration: Double?

    /// Available capture devices, refreshed from the system.
    var inputDevices: [AudioDeviceInfo] = []
    var outputDevices: [AudioDeviceInfo] = []
    var defaultInputDevice: AudioDeviceInfo?
    var defaultOutputDevice: AudioDeviceInfo?
    /// A nil override follows the corresponding system default.
    var selectedOutputUID: String?
    var selectedMicUID: String?
    var includeMicrophone = true
    var selectedRecordingType: RecordingType = .callMeeting
    var liveMeetingEnabled = false
    var automaticLiveMemos = false
    var selectedSpeechLanguage: SpokenLanguage = .auto
    var selectedNotesLanguage: SpokenLanguage = .auto
    var liveMicrophoneEnabled = true
    /// True from just before capture starts until it has stopped: the system tap records
    /// every process, so session playback must stay silent for the whole window.
    var playbackBlocked = false
    private(set) var recordingTransitionInProgress = false
    let liveMeeting = LiveMeetingController()
    let modelCatalog = ModelCatalogService(cacheURL: AppModel.catalogCacheURL)
    /// Last known OpenRouter catalog (cached or freshly fetched); nil before the first fetch.
    var catalogSnapshot: ModelCatalogSnapshot?
    /// Why the last catalog refresh failed (e.g. offline); the cached snapshot stays usable.
    var catalogProblem: String?
    var catalogRefreshing = false

    @ObservationIgnored
    private var audioDeviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    let captureManager = AudioCaptureManager()
    let sessionManager: SessionManager
    let settingsManager: SettingsManager
    let pythonBridge = PythonBridge()
    let diarizationService = DiarizationService(provider: FluidAudioDiarizer())

    /// The in-flight auto-transcription task, retained so the user can cancel it.
    @ObservationIgnored
    private var transcriptionTask: Task<Void, Never>?

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "AppModel"
    )

    /// Creates the app model backed by the given database.
    ///
    /// - Parameter database: The GRDB-backed application database.
    init(database: AppDatabase) {
        self.sessionManager = SessionManager(database: database)
        self.settingsManager = SettingsManager(database: database)
        self.catalogSnapshot = modelCatalog.cached()
        AppModel.shared = self
        observeAudioDevices()
        refreshAudioDevices()
    }

    deinit {
        removeAudioDeviceListeners()
    }

    static var catalogCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallCapture", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("model-catalog.json")
    }

    /// Refreshes the OpenRouter catalog (at most daily unless forced); on failure the
    /// cached snapshot stays in place and `catalogProblem` says why.
    @MainActor func refreshModelCatalog(force: Bool) async {
        guard !catalogRefreshing else { return }
        catalogRefreshing = true
        defer { catalogRefreshing = false }
        do {
            catalogSnapshot = try await modelCatalog.refresh(apiKey: settingsManager.openRouterApiKey, force: force)
            catalogProblem = nil
        } catch {
            catalogProblem = error.localizedDescription
        }
    }

    private func observeAudioDevices() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshAudioDevices()
        }
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
            if status == noErr {
                audioDeviceListeners.append((address, listener))
            } else {
                Self.logger.error("Audio device listener failed: OSStatus=\(status)")
            }
        }
    }

    private func removeAudioDeviceListeners() {
        for (address, listener) in audioDeviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
        }
        audioDeviceListeners.removeAll()
    }

    /// Reloads the available input/output devices from the system and prunes
    /// any selection that no longer exists.
    func refreshAudioDevices() {
        inputDevices = AudioDeviceEnumerator.inputDevices()
        outputDevices = AudioDeviceEnumerator.outputDevices()
        defaultInputDevice = AudioDeviceEnumerator.defaultInputDevice()
        defaultOutputDevice = AudioDeviceEnumerator.defaultOutputDevice()

        if let mic = selectedMicUID,
           !inputDevices.contains(where: { $0.uid == mic }) {
            selectedMicUID = nil
        }
        if let out = selectedOutputUID,
           !outputDevices.contains(where: { $0.uid == out }) {
            selectedOutputUID = nil
        }
        Self.logger.info(
            "Audio devices: \(self.inputDevices.count) input, \(self.outputDevices.count) output"
        )
    }

    /// Synchronously releases audio capture and any running worker process.
    /// Called from `AppDelegate` on app termination and catchable signals.
    func teardownForExit() {
        removeAudioDeviceListeners()
        transcriptionTask?.cancel()
        pythonBridge.cancelCurrentJob()
        captureManager.emergencyStop()
        // AppDelegate dispatches termination and signal handlers on the main queue.
        MainActor.assumeIsolated { liveMeeting.cancel() }
    }

    /// Cancels an in-progress transcription. The recorded audio is preserved
    /// and the session can be re-transcribed later from the session list.
    func cancelTranscription() {
        guard state == .transcribing else { return }
        Self.logger.info("Transcription cancelled by user")
        transcriptionTask?.cancel()
        pythonBridge.cancelCurrentJob()
        state = .idle
    }

    var menuBarIconName: String {
        switch state {
        case .idle: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        case .error: "exclamationmark.circle"
        }
    }

    /// Toggles recording on/off. Creates a new session on start,
    /// finalizes capture on stop.
    @MainActor func toggleRecording() async {
        guard !recordingTransitionInProgress else { return }
        recordingTransitionInProgress = true
        defer { recordingTransitionInProgress = false }
        switch state {
        case .idle, .error:
            state = .idle
            lastError = nil
            await startRecording()
        case .recording:
            await stopRecording()
        case .transcribing:
            break
        }
    }

    /// Transcribes the given session using the Python worker.
    ///
    /// Builds a `JobRequest` from the session and current settings,
    /// runs the worker, then updates the session record with result paths.
    /// Callable from `stopRecording` (auto-transcribe) and from
    /// `SessionDetailView` (manual transcribe button).
    ///
    /// - Parameter session: The session to transcribe.
    func transcribeSession(_ session: Session) async {
        state = .transcribing
        lastError = nil
        Self.logger.info("Transcription started for session \(session.id)")

        sessionManager.updateSessionStatus(
            id: session.id,
            status: "transcribing"
        )

        let request = JobRequest.transcribe(
            session: session,
            settings: settingsManager
        )

        let llmBaseURL: String
        let llmKey: String
        switch settingsManager.llmProvider {
        case .openrouter:
            llmBaseURL = "https://openrouter.ai/api/v1"
            llmKey = settingsManager.openRouterApiKey
        case .local:
            llmBaseURL = settingsManager.localLLMBaseURL
            llmKey = "ollama" // placeholder; local servers ignore it
        }
        var llmEnv = [
            "LLM_BASE_URL": llmBaseURL,
            "LLM_MODEL": settingsManager.model(for: .final),
            "LLM_API_KEY": llmKey,
        ]
        // Remote transcription providers read a provider-specific key from env.
        // For the `.auto` provider we resolve to AssemblyAI or Deepgram based
        // on the session's spoken language AND ship both keys so the worker
        // can use whichever it ends up routing through.
        if request.engine == TranscriptionEngine.remote.rawValue {
            switch settingsManager.remoteProvider {
            case .auto:
                if !settingsManager.assemblyAIApiKey.isEmpty {
                    llmEnv["ASSEMBLYAI_API_KEY"] = settingsManager.assemblyAIApiKey
                }
                if !settingsManager.deepgramApiKey.isEmpty {
                    llmEnv["DEEPGRAM_API_KEY"] = settingsManager.deepgramApiKey
                }
            case .assemblyai:
                if !settingsManager.assemblyAIApiKey.isEmpty {
                    llmEnv["ASSEMBLYAI_API_KEY"] = settingsManager.assemblyAIApiKey
                } else if !settingsManager.remoteApiKey.isEmpty {
                    // Back-compat for users who pasted into the old single field.
                    llmEnv["ASSEMBLYAI_API_KEY"] = settingsManager.remoteApiKey
                }
            case .deepgram:
                if !settingsManager.deepgramApiKey.isEmpty {
                    llmEnv["DEEPGRAM_API_KEY"] = settingsManager.deepgramApiKey
                } else if !settingsManager.remoteApiKey.isEmpty {
                    llmEnv["DEEPGRAM_API_KEY"] = settingsManager.remoteApiKey
                }
            case .groq:
                if !settingsManager.remoteApiKey.isEmpty {
                    llmEnv["GROQ_API_KEY"] = settingsManager.remoteApiKey
                }
            case .openai:
                if !settingsManager.remoteApiKey.isEmpty {
                    llmEnv["OPENAI_API_KEY"] = settingsManager.remoteApiKey
                }
            }
        }

        // Diarize the remote audio and write the turns sidecar the worker reads,
        // before transcription. No-ops unless the recording type diarizes and
        // models are downloaded; never blocks or fails transcription.
        await diarizationService.diarizeIfNeeded(
            session: session,
            modelsReady: settingsManager.diarizationModelsReady
        )

        do {
            let result = try await pythonBridge.runJob(request: request, env: llmEnv)

            if result.status == "error" || result.status == "failed" {
                let message = result.errorMessage
                    ?? result.warnings.first
                    ?? "Transcription failed"
                state = .error
                lastError = message
                sessionManager.updateSessionStatus(
                    id: session.id,
                    status: "error",
                    errorMessage: message
                )
                Self.logger.error(
                    "Transcription error for session \(session.id): \(message)"
                )
                return
            }

            sessionManager.updateSessionPaths(
                id: session.id,
                rawTranscriptPath: result.rawTranscriptPath,
                markdownPath: result.markdownPath,
                engineUsed: request.engine
            )
            sessionManager.updateAnalysisPath(
                id: session.id,
                analysisPath: result.analysisPath
            )
            sessionManager.updateSessionCost(
                id: session.id,
                costTranscription: result.costTranscription,
                costProcessing: result.costProcessing,
                costCurrency: result.costCurrency
            )
            sessionManager.updateSessionStatus(
                id: session.id,
                status: "transcribed"
            )

            state = .idle
            let duration = result.durationSec ?? 0
            Self.logger.info(
                "Transcription completed for session \(session.id), duration=\(duration)s"
            )
        } catch is CancellationError {
            // User cancelled — keep the recorded audio, mark as completed so
            // it can be re-transcribed later from the session list.
            state = .idle
            sessionManager.updateSessionStatus(
                id: session.id,
                status: "completed"
            )
            Self.logger.info(
                "Transcription cancelled for session \(session.id)"
            )
        } catch {
            let message = error.localizedDescription
            state = .error
            lastError = message
            sessionManager.updateSessionStatus(
                id: session.id,
                status: "error",
                errorMessage: message
            )
            Self.logger.error(
                "Transcription failed for session \(session.id): \(error)"
            )
        }
    }

    @MainActor private func startRecording() async {
        do {
            // Serialize the device snapshot with HAL notifications and picker changes.
            let (output, mic) = try await MainActor.run {
                refreshAudioDevices()
                guard let output = AudioDeviceEnumerator.resolveDevice(
                    preferredUID: selectedOutputUID,
                    devices: outputDevices,
                    defaultDevice: defaultOutputDevice
                ) else { throw CaptureError.noDefaultOutputDevice }

                let mic: AudioDeviceInfo?
                if includeMicrophone {
                    guard let input = AudioDeviceEnumerator.resolveDevice(
                        preferredUID: selectedMicUID,
                        devices: inputDevices,
                        defaultDevice: defaultInputDevice
                    ) else { throw CaptureError.noDefaultInputDevice }
                    mic = input
                } else {
                    mic = nil
                }
                return (output, mic)
            }

            let session = sessionManager.createSession(
                sourceApp: "System Audio",
                recordingType: selectedRecordingType,
                language: selectedSpeechLanguage.rawValue,
                notesLanguage: selectedNotesLanguage.rawValue
            )
            let outputURL = session.audioFileURL
            liveMicrophoneEnabled = mic != nil
            if liveMeetingEnabled {
                let provider = settingsManager.llmProvider
                let baseURL = provider == .openrouter ? "https://openrouter.ai/api/v1" : settingsManager.localLLMBaseURL
                let key = provider == .openrouter ? settingsManager.openRouterApiKey : "ollama"
                let configuredURL = URL(string: baseURL)
                let url = configuredURL ?? URL(string: "http://127.0.0.1:11434/v1")!
                liveMeeting.start(session: session, bridge: pythonBridge,
                    modelName: settingsManager.whisperModel.rawValue,
                    speechLanguage: selectedSpeechLanguage.rawValue,
                    notesLanguage: selectedNotesLanguage.rawValue,
                    configuration: LiveNotesConfiguration(enabled: automaticLiveMemos && configuredURL != nil, baseURL: url,
                                                          apiKey: automaticLiveMemos ? key : "", model: settingsManager.model(for: .live),
                                                          listedModelIDs: provider == .openrouter ? catalogSnapshot.map { Set($0.models.map(\.id)) } : nil))
                if automaticLiveMemos && configuredURL == nil {
                    liveMeeting.model.markGap("Invalid memo provider URL; local speech and manual notes continue. Fix the provider in Settings before the next meeting.")
                }
                captureManager.liveBuffer = liveMeeting.buffer
            } else { captureManager.liveBuffer = nil }
            playbackBlocked = true
            SessionAudioPlayer.pauseAll()
            try await captureManager.startCapture(
                outputPath: outputURL,
                outputDeviceUID: output.uid,
                micDeviceUID: mic?.uid
            )
            state = .recording
            Self.logger.info("Recording started for session \(session.id)")
        } catch {
            state = .error
            lastError = error.localizedDescription
            playbackBlocked = false
            captureManager.liveBuffer = nil
            liveMeeting.cancel()
            Self.logger.error("Failed to start recording: \(error)")
        }
    }

    @MainActor private func stopRecording() async {
        do {
            try await captureManager.stopCapture()
            // Stays blocked if stopping failed: the tap may still be running.
            playbackBlocked = false
            captureManager.liveBuffer = nil
            if liveMeeting.model.document.isRecording {
                await liveMeeting.stop(finalOffset: Double(captureManager.liveFrameOffset) / 16_000,
                                       sources: liveMicrophoneEnabled ? [.mic, .system] : [.system])
            }

            guard let session = sessionManager.currentSession else {
                state = .idle
                Self.logger.info("Recording stopped (no active session)")
                return
            }

            sessionManager.finalizeSession()

            // Reload the finalized record so we have the computed duration.
            let finalized = sessionManager.session(id: session.id) ?? session
            lastSessionTitle = finalized.title
            lastSessionDate = finalized.startedAt
            lastSessionDuration = finalized.durationSec

            Self.logger.info("Recording stopped for session \(session.id)")

            if settingsManager.autoProcessOnStop {
                Self.logger.info(
                    "Auto-transcription enabled, starting transcription"
                )
                // Run as a cancellable background task so Stop returns
                // immediately and the user can cancel transcription.
                state = .transcribing
                transcriptionTask = Task { [weak self] in
                    await self?.transcribeSession(finalized)
                }
            } else {
                state = .idle
            }
        } catch {
            state = .error
            lastError = error.localizedDescription
            captureManager.liveBuffer = nil
            liveMeeting.cancel()
            Self.logger.error("Failed to stop recording: \(error)")
        }
    }
}
