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
        // The popover's signal-room faces come from the bundled web UI; before any view.
        SignalFonts.registerBundled()
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

        // Sessions, Settings and the live view are the local web UI (archive window,
        // browser, live panel; see WebWindows.swift). Diagnostics stays native.
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
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

    /// Loopback HTTP server behind the local web UI.
    @ObservationIgnored
    let localServer: LocalServer

    /// Port the local server is bound to; nil until it is serving (or if it failed to start).
    private(set) var localServerPort: Int?

    /// Server-sent events for the web UI (owned by the server backend; see `AppModel+Events`).
    @ObservationIgnored
    let events: EventHub
    /// Keeps the observers behind the events alive.
    @ObservationIgnored
    var eventWatchers: [AnyObject] = []
    /// The last `recording` event sent (so repeated assignments don't repeat it) and the
    /// live model download flag it includes, mirrored from the main actor.
    @ObservationIgnored
    let publishedRecording = OSAllocatedUnfairLock(initialState: RecordingPublication())

    @ObservationIgnored
    private var archiveWindowController: WebWindowController?
    @ObservationIgnored
    private var livePanelController: LivePanelController?

    var state: AppState = .idle { didSet { recordingStateDidChange() } }
    var lastError: String? { didSet { recordingStateDidChange() } }
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
    var playbackBlocked = false { didSet { recordingStateDidChange() } }
    /// The start or stop being worked through; one at a time, from the menu or the web UI.
    var recordingTransition: RecordingTransition? { didSet { recordingStateDidChange() } }
    var recordingTransitionInProgress: Bool { recordingTransition != nil }
    let liveMeeting = LiveMeetingController()
    let connectivity = ConnectivityMonitor()
    /// A non-error note for the menu, e.g. a recording kept until cloud transcription can run.
    var notice: String?
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
        let serverBackend = AppModelBackend()
        self.localServer = LocalServer(backend: serverBackend)
        self.events = serverBackend.events
        self.sessionManager = SessionManager(database: database)
        self.settingsManager = SettingsManager(database: database)
        self.catalogSnapshot = modelCatalog.cached()
        AppModel.shared = self
        serverBackend.attach(self)
        // SwiftUI creates the app (and this model) on the main thread.
        MainActor.assumeIsolated { startPublishingEvents() }
        startLocalServer(portStore: ServerPortStore(database: database))
        Task { @MainActor [weak self] in await self?.refreshModelCatalogIfUseful() }
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

    /// Keeps the cached catalog current (at most daily) so the live-model guard does not
    /// check a list from weeks ago; no request for the Local provider or offline.
    @MainActor func refreshModelCatalogIfUseful() async {
        guard NetworkPolicy.shouldRefreshCatalog(provider: settingsManager.llmProvider,
                                                 isOnline: connectivity.isOnline) else { return }
        await refreshModelCatalog(force: false)
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

    /// Starts the loopback server, on last run's port when it is free (so tabs left open
    /// across a restart are told to sign in again). A failure is logged and never fatal:
    /// the menu-bar app keeps recording without its web UI.
    private func startLocalServer(portStore: ServerPortStore) {
        let server = localServer
        Task {
            do {
                let port = try await server.start(preferring: portStore.load())
                portStore.save(port)
                Self.logger.info("Local server listening on 127.0.0.1:\(port)")
                await MainActor.run { self.localServerPort = port }
            } catch {
                Self.logger.error("Local server failed to start: \(error.localizedDescription)")
            }
        }
    }

    /// Login URL for a local web UI path; nil while the server is not running.
    func webLoginURL(path: String) -> URL? {
        localServerPort == nil ? nil : localServer.loginURL(path: path)
    }

    /// Shows a web UI path (`/sessions`, `/sessions/<id>`, `/settings`) in the archive window.
    @MainActor
    func showArchiveWindow(path: String = "/sessions") {
        let controller = archiveWindowController ?? WebWindowController(
            loginURL: { [weak self] in self?.webLoginURL(path: $0) },
            ownPort: { [weak self] in self?.localServerPort })
        archiveWindowController = controller
        controller.show(path: path)
    }

    @MainActor
    func showLivePanel() {
        let controller = livePanelController ?? LivePanelController(
            loginURL: { [weak self] in self?.webLoginURL(path: $0) },
            ownPort: { [weak self] in self?.localServerPort })
        livePanelController = controller
        controller.show()
    }

    /// Synchronously releases audio capture and any running worker process.
    /// Called from `AppDelegate` on app termination and catchable signals.
    func teardownForExit() {
        removeAudioDeviceListeners()
        transcriptionTask?.cancel()
        pythonBridge.cancelCurrentJob()
        captureManager.emergencyStop()
        // Best effort: the process is exiting, which closes the socket anyway.
        let server = localServer
        Task { await server.stop() }
        // AppDelegate dispatches termination and signal handlers on the main queue.
        MainActor.assumeIsolated { liveMeeting.cancel() }
    }

    /// Processes a session in the background, the way auto-process after Stop does:
    /// the app is marked busy at once and the menu's Cancel can stop the run.
    @MainActor func startTranscription(_ session: Session) {
        state = .transcribing
        // Mark the record now, so a client polling the session never reads the old
        // status as "finished" before `transcribeSession` gets to it.
        sessionManager.updateSessionStatus(id: session.id, status: "transcribing")
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            await self.transcribeSession(session)
            // Every path sets a final status except the wait-for-network early
            // return; undo the mark there and keep the reason on the record.
            if state != .transcribing, sessionManager.session(id: session.id)?.status == "transcribing" {
                sessionManager.updateSessionStatus(id: session.id, status: session.status, errorMessage: lastError)
            }
        }
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

    /// Transcribes the given session using the Python worker.
    ///
    /// Builds a `JobRequest` from the session and current settings,
    /// runs the worker, then updates the session record with result paths.
    /// Callable from `stopRecording` (auto-transcribe) and from `startTranscription`
    /// (the web UI's Transcribe / Re-process / Retry).
    ///
    /// - Parameter session: The session to transcribe.
    func transcribeSession(_ session: Session) async {
        let request = JobRequest.transcribe(
            session: session,
            settings: settingsManager
        )
        let decision = NetworkPolicy.decision(engine: request.engine, provider: settingsManager.llmProvider,
                                              isOnline: await connectivity.isOnline)
        if case .wait(let message) = decision {
            state = .error
            lastError = message
            return
        }

        state = .transcribing
        lastError = nil
        notice = nil
        Self.logger.info("Transcription started for session \(session.id)")

        sessionManager.updateSessionStatus(
            id: session.id,
            status: "transcribing"
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
        // Offline with OpenRouter notes: the worker skips the LLM and says so in warnings.
        llmEnv.merge(decision.workerEnvironment) { _, new in new }
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
            sessionManager.updateSessionWarning(
                id: session.id,
                message: result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
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

    /// Call through `beginRecordingTransition(.starting)` (see `AppModel+Recording`).
    @MainActor func startRecording() async {
        notice = nil
        // Freshen a stale catalog in the background; this meeting uses what is cached now.
        Task { [weak self] in await self?.refreshModelCatalogIfUseful() }
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
                let memosOffline = automaticLiveMemos && provider == .openrouter && !connectivity.isOnline
                liveMeeting.start(session: session, bridge: pythonBridge,
                    modelName: settingsManager.whisperModel.rawValue,
                    speechLanguage: selectedSpeechLanguage.rawValue,
                    notesLanguage: selectedNotesLanguage.rawValue,
                    configuration: LiveNotesConfiguration(enabled: automaticLiveMemos && !memosOffline && configuredURL != nil, baseURL: url,
                                                          apiKey: automaticLiveMemos ? key : "", model: settingsManager.model(for: .live),
                                                          listedModelIDs: provider == .openrouter ? catalogSnapshot.map { Set($0.models.map(\.id)) } : nil))
                if memosOffline {
                    liveMeeting.model.markGap("Automatic notes off: offline. Local transcript and manual notes continue.")
                }
                if automaticLiveMemos && configuredURL == nil {
                    liveMeeting.model.markGap("Invalid memo provider URL; local speech and manual notes continue. Fix the provider in Settings before the next meeting.")
                }
                captureManager.liveBuffer = liveMeeting.buffer
            } else { captureManager.liveBuffer = nil }
            // Web players pause on the `recording` event this publishes.
            playbackBlocked = true
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

    /// Call through `beginRecordingTransition(.stopping)` (see `AppModel+Recording`).
    @MainActor func stopRecording() async {
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

            let autoEngine = JobRequest.transcribe(session: finalized, settings: settingsManager).engine
            if settingsManager.autoProcessOnStop,
               case .wait(let message) = NetworkPolicy.decision(engine: autoEngine, provider: settingsManager.llmProvider,
                                                                isOnline: connectivity.isOnline) {
                // Keep the recording; nothing is sent until the user transcribes.
                notice = message
                state = .idle
            } else if settingsManager.autoProcessOnStop {
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
