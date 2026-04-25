import SwiftUI
import Carbon
import Combine
import HotKey
import os

enum AppState: Equatable, Sendable {
    case idle
    case recording
    /// V3: recording + streaming chunk injection in progress.
    case streaming(chunkCount: Int)
    case transcribing
    case injecting
    case undoable(text: String, method: InjectionMethod)
    case error(MurmurError)

    static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.recording, .recording),
             (.transcribing, .transcribing), (.injecting, .injecting):
            return true
        case (.streaming(let a), .streaming(let b)):
            return a == b
        case (.undoable(let a, let am), .undoable(let b, let bm)):
            return a == b && am == bm
        case (.error, .error):
            return true
        default:
            return false
        }
    }

    var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }

    var statusText: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .streaming: return "Listening..."
        case .transcribing: return "Transcribing..."
        case .injecting: return "Inserting text..."
        case .undoable(let text, _): return String(text.prefix(40))
        case .error(let err): return err.localizedDescription
        }
    }
}

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var state: AppState = .idle
    @Published var lastTranscription: String?
    @Published var lastLanguage: DetectedLanguage?
    @Published private(set) var currentAudioLevel: Float = 0
    /// In-memory recent transcriptions. `rawText` is populated only when the
    /// LLM correction step actually changed the transcribed words (e.g.
    /// homophone fix), so the menu-bar UI can show the user a before/after
    /// diff when correction is on. Rule-based cleanup (punctuation/casing) is
    /// NOT reflected here — its effect is deterministic and not interesting
    /// to compare. nil `rawText` means "no correction diff to show."
    @Published private(set) var transcriptionHistory: [(text: String, rawText: String?, language: DetectedLanguage, date: Date)] = []

    private let maxHistoryCount = 20

    let hotkey: HotkeyService
    let audio: AudioService
    private(set) var transcription: any TranscriptionServiceProtocol
    let injection: TextInjectionService
    let permissions: PermissionsService
    let audioFeedback: AudioFeedbackService
    let pill: any PillControlling

    /// Optional audio-based language identifier. When nil or when the
    /// `autoDetectLanguage` default is off, language resolution falls through
    /// to the synchronous input-source heuristic. Injected by MurmurApp once
    /// the auxiliary LID model has been downloaded.
    var lid: (any LanguageIdentifying)?

    /// Optional post-transcription cleanup service. When non-nil and the
    /// `cleanupTranscription` UserDefault is on, called after V1 transcription
    /// succeeds and before text is injected. Injected by MurmurApp on every
    /// launch (rule-based; no download gate in v0.3.0).
    var cleanup: (any TranscriptionCleanup)?

    /// Optional ASR error-correction service. When non-nil and the
    /// `correctTranscription` UserDefault is on, runs BEFORE `cleanup` on the
    /// raw transcribed text. Concrete implementation is chosen by
    /// `reconfigureCorrectionEngine()` based on the `correctionEngine`
    /// UserDefault: `"apple"` → `FoundationModelsCorrector` (or NoOp on
    /// older systems), `"ollama"` → `OllamaCorrector`. Re-wired whenever
    /// Settings changes the picker values.
    var correction: (any TranscriptionCorrection)?

    /// Re-reads `correctionEngine`, `localLLMBaseURL`, `localLLMModel`, and
    /// `localLLMAPIKey` from UserDefaults and wires the appropriate concrete
    /// corrector into `self.correction`. Safe to call repeatedly — each call
    /// is cheap. Invoke from MurmurApp at launch and from Settings whenever
    /// the engine picker / URL / model fields change.
    func reconfigureCorrectionEngine() {
        let defaults = UserDefaults.standard
        let engine = defaults.string(forKey: "correctionEngine") ?? "apple"

        switch engine {
        case "local":
            // Any OpenAI-compatible local server (Ollama, LM Studio, llamafile, …).
            // User fills in the full base URL including `/v1`.
            let urlString = defaults.string(forKey: "localLLMBaseURL") ?? "http://localhost:11434/v1"
            let model = defaults.string(forKey: "localLLMModel") ?? "qwen2.5:3b-instruct"
            let apiKey = defaults.string(forKey: "localLLMAPIKey")
            if let url = URL(string: urlString) {
                self.correction = OpenAICompatibleCorrector(
                    baseURL: url,
                    modelName: model,
                    apiKey: (apiKey?.isEmpty ?? true) ? nil : apiKey
                )
                Self.log.info("correction engine: local @ \(urlString, privacy: .public) (\(model, privacy: .public))")
            } else {
                Self.log.error("correction engine: invalid local URL \(urlString, privacy: .public); falling back to NoOp")
                self.correction = NoOpCorrector()
            }

        default:
            // "apple" or unknown — prefer Foundation Models when available.
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), FoundationModelsCorrector.isSystemModelAvailable {
                self.correction = FoundationModelsCorrector()
                Self.log.info("correction engine: apple on-device")
                return
            }
            #endif
            self.correction = NoOpCorrector()
            Self.log.info("correction engine: noop (apple unavailable)")
        }
    }

    private var cleanupEnabled: Bool {
        UserDefaults.standard.bool(forKey: "cleanupTranscription")
    }

    private var correctionEnabled: Bool {
        UserDefaults.standard.bool(forKey: "correctTranscription")
    }

    /// Minimum softmax confidence required to trust a detected language. Below
    /// this threshold we fall back to the manual Picker (or "auto" heuristic),
    /// so a brief grunt or multilingual utterance does not flip to the wrong
    /// language. Tunable from real-world logs — see .public LID log lines.
    private static let lidConfidenceThreshold: Float = 0.60

    // MARK: - V3 Streaming (feature-flag gated)

    private(set) var streamingCoordinator: StreamingTranscriptionCoordinator?

    private var isStreamingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "streamingInputEnabled")
    }

    /// When true, skips accessibility check (for onboarding test where we show text in-app, not inject)
    var skipAccessibilityCheck = false

    /// Update the transcription backend model path (called when user switches backends)
    func switchModelPath(_ newPath: URL) {
        Task {
            await transcription.setModelPath(newPath)
        }
        preloadModelInBackground()
    }

    /// Replace the transcription service (e.g. when switching between ONNX and Python backends)
    func replaceTranscriptionService(_ newService: any TranscriptionServiceProtocol) {
        Task { await transcription.killProcess() }
        transcription = newService
        preloadModelInBackground()
    }

    /// Preload the model so the first transcription is instant.
    /// Cancels any in-flight preload to avoid concurrent `send()` calls
    /// that would corrupt the JSON protocol.
    private var preloadTask: Task<Void, Never>?

    func preloadModelInBackground() {
        preloadTask?.cancel()
        preloadTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.transcription.preloadModel()
                Self.log.info("Model preloaded successfully")
            } catch {
                if !Task.isCancelled {
                    Self.log.warning("Model preload failed (will retry on first use): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
    private var pendingRecording = false
    private var undoTimer: Task<Void, Never>?
    private var hotkeyTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var undoMonitor: Any?
    // Exposed as internal(set) so tests can assert the badge value without
    // needing to spy on the full stopAndTranscribeV1 call path (which requires
    // live audio infrastructure).
    internal(set) var activeBadge: String? = nil
    private static let transcriptionLanguageKey = "transcriptionLanguage"
    private static let log = Logger(subsystem: "com.murmur.app", category: "coordinator")

    init(
        hotkey: HotkeyService = HotkeyService(),
        audio: AudioService = AudioService(),
        transcription: any TranscriptionServiceProtocol = TranscriptionService(),
        injection: TextInjectionService = TextInjectionService(),
        permissions: PermissionsService = PermissionsService(),
        audioFeedback: AudioFeedbackService = AudioFeedbackService(),
        pill: any PillControlling = FloatingPillController()
    ) {
        self.hotkey = hotkey
        self.audio = audio
        self.transcription = transcription
        self.injection = injection
        self.permissions = permissions
        self.audioFeedback = audioFeedback
        self.pill = pill
        self.streamingCoordinator = StreamingTranscriptionCoordinator(
            transcription: transcription,
            injection: injection
        )

        // Defer start to next run loop to ensure StateObject is fully initialized
        Task { @MainActor [weak self] in
            self?.start()
        }
    }

    private func start() {
        // Load saved recording mode
        if let modeStr = UserDefaults.standard.string(forKey: "recordingMode"),
           let mode = RecordingMode(rawValue: modeStr) {
            hotkey.setMode(mode)
        }

        // Load saved hotkey or use default (right command)
        if let keyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int,
           let modsRaw = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt,
           let key = Key(carbonKeyCode: UInt32(keyCode)) {
            hotkey.register(trigger: .keyCombo(key: key, modifiers: NSEvent.ModifierFlags(rawValue: modsRaw)))
        } else {
            hotkey.register(trigger: .rightCommand)
        }

        hotkeyTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.hotkey.events {
                await self.handleHotkeyEvent(event)
            }
        }

        // Unload model on sleep, re-preload on wake
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.transcription.unloadModel() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.preloadModelInBackground()
        }

        // Preload model in background so first transcription is instant
        preloadModelInBackground()

        Self.log.info("Coordinator started")
    }

    func stop() {
        hotkeyTask?.cancel()
        audioLevelTask?.cancel()
        longTranscribeTask?.cancel()
        hotkey.unregister()
        audio.cancelRecording()
        Task { await transcription.killProcess() }
    }

    // MARK: - Window Transcription Coordination

    /// Called by TranscriptionWindowModel when the user initiates transcription
    /// in the transcription window. Transitions the coordinator to .transcribing
    /// so the global hotkey guard blocks new recordings (voice input paused).
    ///
    /// Must only be called when coordinator is currently .idle or .error.
    func beginWindowTranscription() {
        guard state == .idle || state.isError else { return }
        transition(to: .transcribing)
    }

    /// Called by TranscriptionWindowModel when window transcription ends
    /// (success, cancel, or error). Releases the .transcribing hold so
    /// voice input (hotkey) resumes.
    func endWindowTranscription() {
        guard state == .transcribing else { return }
        transition(to: .idle)
    }

    // MARK: - Long Transcription

    /// Task handle for an in-flight transcribeLong operation.
    /// Cancel this to abort chunked transcription and resume voice input.
    private(set) var longTranscribeTask: Task<Void, Never>?

    /// Transcribe a long audio file using chunked processing.
    ///
    /// - Pauses voice input (hotkey suppressed while state == .transcribing).
    /// - Reports progress via `onProgress` callback on the Main actor.
    /// - Resumes voice input (state → .idle) on completion, error, or cancellation.
    ///
    /// Only one call may run at a time; a second call cancels the first.
    func transcribeLong(
        audioURL: URL,
        onProgress: @escaping @MainActor (TranscriptionProgress) -> Void
    ) {
        // Cancel any prior long transcription
        longTranscribeTask?.cancel()

        longTranscribeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Pause voice input — hotkey guard already blocks new recordings while .transcribing
            self.transition(to: .transcribing)
            self.pill.show(state: .transcribing)

            let lang = await self.resolveTranscriptionLanguageAsync(audioURL: audioURL)

            do {
                let result = try await self.transcription.transcribeLong(
                    audioURL: audioURL,
                    language: lang,
                    onProgress: { progress in
                        Task { @MainActor in onProgress(progress) }
                    }
                )

                self.transition(to: .injecting)
                self.pill.show(state: .injecting)

                let method = try await withTimeout(seconds: 5, operation: "text injection") {
                    try await self.injection.inject(text: result.text)
                }

                self.lastTranscription = result.text
                self.lastLanguage = result.language
                // transcribeLong path does not currently run the correction
                // pipeline, so rawText is always nil here.
                self.transcriptionHistory.insert(
                    (text: result.text, rawText: nil, language: result.language, date: Date()), at: 0
                )
                if self.transcriptionHistory.count > self.maxHistoryCount {
                    self.transcriptionHistory.removeLast()
                }

                let undoableState = AppState.undoable(text: result.text, method: method)
                self.transition(to: undoableState)
                // No success chime: inserted text is visually self-evident.
                self.pill.show(state: undoableState)
                self.pill.hide(after: 2)

            } catch is CancellationError {
                // P1-3 fix: match on the error type, not Task.isCancelled.
                // Task.isCancelled in a catch block queries the *current task's*
                // cancellation flag, which may be true even when the thrown error
                // is a real failure that arrived before the cancel signal.
                self.transition(to: .idle)
                self.pill.hide()
            } catch {
                self.handleError(self.mapError(error))
            }
        }
    }

    // MARK: - Event Handling

    private func handleHotkeyEvent(_ event: HotkeyEvent) async {
        switch event {
        case .startRecording:
            // Pre-check: without a downloaded model the streaming pipeline would
            // silently swallow transcription errors (processChunkBuffer logs and
            // continues; full-pass transitions to .done on failure). Catch it
            // here and surface a proper NSAlert before the user wastes a
            // recording on a session that can't produce text.
            guard Self.isActiveBackendModelInstalled else {
                handleError(.modelNotFound)
                return
            }
            let status = permissions.checkAll()
            if status.microphone == .notDetermined {
                let granted = await permissions.requestMicrophone()
                if !granted {
                    transition(to: .error(.permissionRevoked(.microphone)))
                    return
                }
            } else if status.microphone != .granted {
                transition(to: .error(.permissionRevoked(.microphone)))
                return
            }
            if !skipAccessibilityCheck && status.accessibility != .granted {
                transition(to: .error(.permissionRevoked(.accessibility)))
                return
            }
            if state == .idle || state.isError || state.isUndoable {
                if state.isUndoable {
                    undoTimer?.cancel()
                    removeUndoMonitor()
                }
                await startRecordingFlow()
            } else if state == .transcribing || state == .injecting {
                pendingRecording = true
                Self.log.info("Recording queued (current state: \(String(describing: self.state)))")
            }

        case .stopRecording:
            guard state == .recording else { return }
            await stopAndTranscribe()

        case .cancelRecording:
            guard state == .recording else { return }
            audio.detachStreamingAccumulator()
            streamingCoordinator?.cancelSession()
            streamingCoordinator?.resetToIdle()
            audio.cancelRecording()
            // No sound: user just pressed Escape; pill.hide() is the confirmation.
            pill.hide()
            transition(to: .idle)
        }
    }

    private func startRecordingFlow() async {
        if isStreamingEnabled {
            await startStreamingRecordingFlow()
        } else {
            await startV1RecordingFlow()
        }
    }

    // MARK: - V1 Recording Flow (unchanged)

    private func startV1RecordingFlow() async {
        do {
            let resolvedLang = resolveTranscriptionLanguage()
            let storedSetting = UserDefaults.standard.string(forKey: Self.transcriptionLanguageKey) ?? "auto"
            activeBadge = LanguageBadge.badgeText(resolvedCode: resolvedLang, storedSetting: storedSetting)

            transition(to: .recording)
            audioFeedback.playStartRecording()
            let cancelHandler: () -> Void = { [weak self] in self?.hotkey.emit(.cancelRecording) }
            pill.show(state: .recording, audioLevel: 0, languageBadge: activeBadge, onCancel: cancelHandler)

            // Monitor audio levels for the pill
            audioLevelTask?.cancel()
            audioLevelTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await level in self.audio.audioLevel {
                    self.currentAudioLevel = level
                    self.pill.show(state: .recording, audioLevel: level, languageBadge: self.activeBadge, onCancel: cancelHandler)
                }
            }

            try await withTimeout(seconds: 5, operation: "start recording") {
                try await self.audio.startRecording()
            }

            // M3: Monitor max recording duration
            maxDurationTask?.cancel()
            maxDurationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await _ in self.audio.maxDurationReached {
                    guard self.state == .recording else { continue }
                    Self.log.info("Max recording duration reached, auto-stopping")
                    await self.stopAndTranscribe()
                    break
                }
            }
        } catch {
            audioLevelTask?.cancel()
            maxDurationTask?.cancel()
            audioFeedback.playError()
            transition(to: .error(mapError(error)))
        }
    }

    // MARK: - V3 Streaming Recording Flow

    private var streamingAccumulator: AudioBufferAccumulator?

    private func startStreamingRecordingFlow() async {
        do {
            // Resolve badge before showing pill — mirrors V1 flow
            let lang = resolveTranscriptionLanguage()
            let storedSetting = UserDefaults.standard.string(forKey: Self.transcriptionLanguageKey) ?? "auto"
            activeBadge = LanguageBadge.badgeText(resolvedCode: lang, storedSetting: storedSetting)

            transition(to: .recording)
            audioFeedback.playStartRecording()
            let cancelHandler: () -> Void = { [weak self] in self?.hotkey.emit(.cancelRecording) }
            pill.show(state: .streaming(chunkCount: 0), audioLevel: 0, languageBadge: activeBadge, onCancel: cancelHandler)

            audioLevelTask?.cancel()
            audioLevelTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await level in self.audio.audioLevel {
                    self.currentAudioLevel = level
                    // Pill update happens via streamingCoordinator published state
                    if case .streaming(let n) = self.streamingCoordinator?.sessionState {
                        self.pill.show(state: .streaming(chunkCount: n), audioLevel: level, languageBadge: self.activeBadge, onCancel: cancelHandler)
                    }
                }
            }

            try await withTimeout(seconds: 5, operation: "start recording") {
                try await self.audio.startRecording()
            }

            // Resolve insertion point before any text is injected (lang already resolved above)
            let startOffset = resolveCurrentCursorOffset()
            let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            let wavURL = audio.currentRecordingURL ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("murmur_stream_\(UUID().uuidString).wav")

            let acc = streamingCoordinator?.beginSession(
                language: lang,
                targetAppPID: targetPID,
                startOffset: startOffset,
                fullWavURL: wavURL
            )
            streamingAccumulator = acc

            // Attach accumulator to audio tap via AudioService dual-output extension
            audio.attachStreamingAccumulator(acc)

            maxDurationTask?.cancel()
            maxDurationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await _ in self.audio.maxDurationReached {
                    guard self.state == .recording else { continue }
                    Self.log.info("Max recording duration reached, auto-stopping (streaming)")
                    await self.stopAndTranscribeStreaming()
                    break
                }
            }
        } catch {
            audioLevelTask?.cancel()
            maxDurationTask?.cancel()
            streamingCoordinator?.cancelSession()
            audioFeedback.playError()
            transition(to: .error(mapError(error)))
        }
    }

    private func stopAndTranscribeStreaming() async {
        audioLevelTask?.cancel()
        maxDurationTask?.cancel()
        // No stop sound: release is user-initiated, already known to the user.
        // Pill transitions ("Listening..." → "Transcribing...") provide visual
        // confirmation; V1 success chime still confirms the system event of
        // transcription completing.

        audio.detachStreamingAccumulator()

        do {
            transition(to: .transcribing)
            pill.show(state: .transcribing)

            let wav = try await withTimeout(seconds: 5, operation: "stop recording") {
                try await self.audio.stopRecording()
            }

            // Pass the full WAV URL to the coordinator for the full-pass
            streamingCoordinator?.updateFullWavURL(wav)
            streamingCoordinator?.endSession()

            // Wait for coordinator to reach done/cancelled/failed
            await waitForStreamingDone()

            // Check how the session ended and show appropriate feedback.
            if let reason = streamingCoordinator?.cancellationReason {
                switch reason {
                case .focusAbandoned:
                    // UT-P1: Notify user that session was abandoned due to app switch.
                    handleError(.sessionAbandoned)
                case .backstopTimeout:
                    handleError(.timeout(operation: "Streaming"))
                case .user:
                    transition(to: .idle)
                    pill.hide(after: 0.5)
                }
            } else if streamingCoordinator?.didTriggerCPUFallback == true {
                // UT-P1: Inform user that streaming was paused due to high CPU.
                // Full-pass still ran, so show result normally but with a note.
                // Success sound already fired on .finalizing transition (see waitForStreamingDone).
                if let replacedText = streamingCoordinator?.fullPassReplacedText {
                    let undoableState = AppState.undoable(text: replacedText, method: .clipboard)
                    transition(to: undoableState)
                    pill.show(state: undoableState)
                    pill.hide(after: 3)
                } else {
                    transition(to: .idle)
                    pill.hide(after: 1)
                }
            } else if let replacedText = streamingCoordinator?.fullPassReplacedText {
                let undoableState = AppState.undoable(text: replacedText, method: .clipboard)
                transition(to: undoableState)
                pill.show(state: undoableState)
                pill.hide(after: 3)
            } else {
                transition(to: .idle)
                pill.hide(after: 1)
            }

        } catch {
            streamingCoordinator?.cancelSession()
            handleError(mapError(error))
        }

        // Reset coordinator so next session can begin
        streamingCoordinator?.resetToIdle()

        if pendingRecording {
            pendingRecording = false
            await startRecordingFlow()
        }
    }

    /// Hard backstop timeout for waitForStreamingDone, independent of state emissions.
    /// Prevents UI hang if coordinator gets stuck without emitting new state (NEW-P1-2).
    private static let streamingDoneBackstopSeconds: TimeInterval = 35

    private func waitForStreamingDone() async {
        guard let coordinator = streamingCoordinator else { return }

        // NEW-P1-2: Wrap the entire Combine-based wait in a backstop timeout.
        // If the coordinator stalls with no state emission (task starvation, deadlock),
        // the for-await loop never evaluates the deadline check. This outer timeout
        // guarantees we always return within a bounded time.
        await withTaskGroup(of: Void.self) { group in
            // Backstop: cancel the group after the hard deadline.
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.streamingDoneBackstopSeconds))
                guard !Task.isCancelled else { return }
                Self.log.warning("waitForStreamingDone: backstop timeout (\(Self.streamingDoneBackstopSeconds)s) — forcing cancel")
                await MainActor.run {
                    coordinator.cancellationReason = .backstopTimeout
                    coordinator.cancelSession()
                }
            }

            // Main wait: subscribe to state changes.
            group.addTask { @MainActor in
                let stream = AsyncStream<StreamingSessionState> { continuation in
                    let cancellable = coordinator.$sessionState.sink { state in
                        continuation.yield(state)
                    }
                    continuation.onTermination = { _ in
                        cancellable.cancel()
                    }
                }

                let deadline = Date().addingTimeInterval(30)
                var warningSent = false

                for await state in stream {
                    switch state {
                    case .done, .cancelled, .failed:
                        return
                    case .finalizing:
                        // Deliberately no success chime on the streaming path.
                        // Text appears progressively during recording, the stop
                        // sound already plays on hotkey release, and the pill's
                        // "Inserted" label covers the visual confirmation. A
                        // chime here either fires before the tail chunk's text
                        // (sound → text gap) or after the full-pass (text →
                        // sound gap, originally 1–15s) — both felt off in
                        // testing.
                        if !warningSent,
                           let startedAt = coordinator.finalizingStartedAt,
                           Date().timeIntervalSince(startedAt) >= StreamingTranscriptionCoordinator.fullPassWarningSeconds {
                            warningSent = true
                            Self.log.info("waitForStreamingDone: full-pass taking >15s, user notified via pill")
                        }
                        if Date() >= deadline {
                            coordinator.cancelSession()
                            return
                        }
                    default:
                        break
                    }
                }
            }

            // Whichever finishes first cancels the other.
            await group.next()
            group.cancelAll()
        }
    }

    private func resolveCurrentCursorOffset() -> Int {
        resolveAXCursorOffset() ?? 0
    }

    // MARK: - V1 Stop & Transcribe (unchanged logic, extracted)

    private func stopAndTranscribe() async {
        if isStreamingEnabled {
            await stopAndTranscribeStreaming()
            return
        }
        await stopAndTranscribeV1()
    }

    private func stopAndTranscribeV1() async {
        audioLevelTask?.cancel()
        maxDurationTask?.cancel()
        // No stop sound: release is user-initiated. Success chime on inject
        // confirms the system event once transcription finishes.

        do {
            transition(to: .transcribing)
            pill.show(state: .transcribing)

            let wav = try await withTimeout(seconds: 5, operation: "stop recording") {
                try await self.audio.stopRecording()
            }
            let lang = await resolveTranscriptionLanguageAsync(audioURL: wav)
            // If LID overrode the IME language, update the badge so the pill
            // reflects what will actually be transcribed before the result arrives.
            let storedSetting = UserDefaults.standard.string(forKey: Self.transcriptionLanguageKey) ?? "auto"
            let resolvedBadge = LanguageBadge.badgeText(resolvedCode: lang, storedSetting: storedSetting)
            if resolvedBadge != activeBadge {
                activeBadge = resolvedBadge
                pill.show(state: .transcribing, languageBadge: activeBadge)
            }
            let result = try await withTimeout(seconds: 120, operation: "transcription") {
                return try await self.transcription.transcribe(audioURL: wav, language: lang)
            }

            // Pipeline: transcribe → correction (LLM, 2.5 s cap) → cleanup (rules, 250 ms cap) → inject.
            // Each step silently falls back to its input on timeout or error.
            let rawTranscribed = result.text
            let corrected = await applyCorrectionIfEnabled(text: rawTranscribed, language: lang)
            let textToInject = await applyCleanupIfEnabled(text: corrected, language: lang)

            transition(to: .injecting)
            pill.show(state: .injecting)

            let method = try await withTimeout(seconds: 5, operation: "text injection") {
                try await self.injection.inject(text: textToInject)
            }

            lastTranscription = textToInject
            lastLanguage = result.language
            // History records the injected (final) text. `rawText` captures the
            // pre-correction transcription only when correction actually changed
            // words (homophone fix, character substitution) — that is the only
            // transformation the user wants to verify. Rule-based cleanup
            // (punctuation/casing) is not surfaced because it is deterministic.
            let rawForHistory: String? = (corrected != rawTranscribed) ? rawTranscribed : nil
            transcriptionHistory.insert((text: textToInject, rawText: rawForHistory, language: result.language, date: Date()), at: 0)
            if transcriptionHistory.count > maxHistoryCount {
                transcriptionHistory.removeLast()
            }

            // Increment V1 usage counter for discovery badge
            V1UsageCounter.increment()

            let undoableState = AppState.undoable(text: textToInject, method: method)
            transition(to: undoableState)
            // No success chime: user can see the text appear in their editor
            // and the "Inserted" pill confirms it. A sound is redundant. Error
            // path still plays error sound because failures have no visual
            // equivalent.
            pill.show(state: undoableState)
            pill.hide(after: 2)
            // Undo timer + Cmd+Z monitor set up automatically by transition(to: .undoable)
        } catch {
            handleError(mapError(error))
        }

        // Drain pending recording
        if pendingRecording {
            pendingRecording = false
            await startRecordingFlow()
        }
    }

    /// Runs the cleanup service if the toggle is on and a service is wired in.
    /// Always returns a valid string: the cleaned text on success, `rawText` on
    /// timeout, throw, or toggle-off. Never surfaces an error to the caller.
    private func applyCleanupIfEnabled(text rawText: String, language: String) async -> String {
        guard cleanupEnabled, let cleanup else { return rawText }
        do {
            let cleaned = try await withTimeout(seconds: Self.cleanupTimeoutSeconds, operation: "cleanup") {
                try await cleanup.improve(rawText, language: language)
            }
            return cleaned
        } catch {
            Self.log.warning("Cleanup failed, using raw text: \(String(describing: error), privacy: .public)")
            return rawText
        }
    }

    /// Runs the ASR-error correction service if the toggle is on and a service
    /// is wired in. Silent fallback to `rawText` on timeout, throw, toggle-off,
    /// or if the safety rails in `TranscriptionCorrection` reject the candidate.
    /// Generative LLM inference is given a longer budget than rule-based cleanup.
    private func applyCorrectionIfEnabled(text rawText: String, language: String) async -> String {
        guard correctionEnabled, let correction else { return rawText }
        do {
            let corrected = try await withTimeout(seconds: Self.correctionTimeoutSeconds, operation: "correction") {
                try await correction.correct(rawText, language: language)
            }
            return corrected
        } catch {
            Self.log.warning("Correction failed, using raw text: \(String(describing: error), privacy: .public)")
            return rawText
        }
    }

    /// Hard cap for post-transcription cleanup (250 ms per spec).
    private static let cleanupTimeoutSeconds: TimeInterval = 0.25

    /// Hard cap for ASR-error correction. 2.5 s accommodates Apple Foundation
    /// Models first-token + generation on M-series; shorter would cause a
    /// fallback on nearly every invocation when the session is cold.
    private static let correctionTimeoutSeconds: TimeInterval = 2.5

#if DEBUG
    /// Testable entry-point that bypasses audio I/O. Exercises the transcribe →
    /// cleanup → inject pipeline with a pre-recorded WAV and a pre-resolved
    /// language code. Only used by `CoordinatorCleanupTests`.
    func stopAndTranscribeV1ForTesting(wav: URL, lang: String) async {
        do {
            let result = try await withTimeout(seconds: 120, operation: "transcription") {
                return try await self.transcription.transcribe(audioURL: wav, language: lang)
            }

            let rawTranscribed = result.text
            let corrected = await applyCorrectionIfEnabled(text: rawTranscribed, language: lang)
            let textToInject = await applyCleanupIfEnabled(text: corrected, language: lang)

            // Skip real injection in tests — just record what would be injected.
            lastTranscription = textToInject
            lastLanguage = result.language
            let rawForHistory: String? = (corrected != rawTranscribed) ? rawTranscribed : nil
            transcriptionHistory.insert((text: textToInject, rawText: rawForHistory, language: result.language, date: Date()), at: 0)
            if transcriptionHistory.count > maxHistoryCount {
                transcriptionHistory.removeLast()
            }

            // method hardcoded — tests here don't assert on injection method;
            // see AppCoordinatorTests for real injection coverage.
            transition(to: .undoable(text: textToInject, method: .clipboard))
        } catch {
            handleError(mapError(error))
        }
    }
#endif

    // MARK: - Helpers

    private var isUndoEnabled: Bool {
        UserDefaults.standard.bool(forKey: "undoAfterTranscription")
    }

    private func transition(to newState: AppState) {
        // Skip undoable state when undo is disabled
        let effectiveState: AppState
        if case .undoable = newState, !isUndoEnabled {
            effectiveState = .idle
        } else {
            effectiveState = newState
        }

        let old = state
        state = effectiveState
        Self.log.info("State: \(String(describing: old), privacy: .public) → \(String(describing: effectiveState), privacy: .public)")

        if case .error(let err) = effectiveState {
            Self.log.error("Entered error state: \(String(describing: err), privacy: .public) — \(err.localizedDescription, privacy: .public)")
        }

        // Auto-transition from undoable to idle after 5s (covers both V1 and streaming)
        if case .undoable = effectiveState {
            setupUndoAutoRecovery()
        }

        // Permission errors show a blocking alert; other errors auto-recover.
        // Surface every error to the unified log so user-reported issues can be
        // diagnosed without repro steps. Read via Console.app, filter by
        // subsystem=com.murmur.app. String(describing:) prints the enum case and
        // associated values — more useful than localizedDescription for debugging.
        if case .error(let err) = newState {
            Self.log.error("Entered error state: \(String(describing: err)) — \(err.localizedDescription)")
            if case .permissionRevoked(let perm) = err {
                showPermissionAlert(for: perm)
            } else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Self.errorAutoRecoverySeconds))
                    guard let self else { return }
                    if case .error = self.state {
                        self.state = .idle
                        self.pill.hide()
                    }
                }
            }
        }
    }

    /// How long a transient error pill stays visible before auto-hiding.
    /// The pill shows the short label (e.g. "Model missing"); full detail is
    /// in the NSAlert for critical errors and the unified log for everything.
    private static let errorAutoRecoverySeconds: TimeInterval = 4

    /// Fast readiness check for the currently selected backend — is a
    /// manifest.json (FU-04 "download + verify completed" marker) present
    /// on disk for the active backend? Used by the startRecording pre-check
    /// to avoid wasting a recording session when no model is installed.
    private static var isActiveBackendModelInstalled: Bool {
        let saved = UserDefaults.standard.string(forKey: "modelBackend") ?? "onnx"
        let subdir: String
        switch saved {
        case "huggingface": subdir = "Murmur/Models"
        case "whisper": subdir = "Murmur/Models-Whisper"
        default: subdir = "Murmur/Models-ONNX"
        }
        let manifestURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(subdir)
            .appendingPathComponent("manifest.json")
        return FileManager.default.fileExists(atPath: manifestURL.path)
    }

    /// Central error-presentation funnel. Every catch block that maps a thrown
    /// error into a user-visible failure should go through here.
    ///
    /// - Critical errors (model missing, disk full, permission revoked) pop an
    ///   NSAlert — the user must acknowledge them before continuing.
    /// - Transient errors (timeouts, silence, transcription failures) flash a
    ///   short pill with `err.shortMessage` and auto-hide after a few seconds.
    ///
    /// Full-detail copy for both paths lives on MurmurError (`errorDescription`
    /// / `alertTitle` / `shortMessage`) and is also logged via `Self.log.error`
    /// in `transition(to:)`.
    private func handleError(_ err: MurmurError) {
        // transition() logs the error and triggers the permission alert
        // (which has its own button layout). Nothing else to do for that path.
        transition(to: .error(err))
        if case .permissionRevoked = err { return }

        audioFeedback.playError()

        switch err.severity {
        case .critical:
            showCriticalErrorAlert(for: err)
        case .transient:
            pill.show(state: .error(err))
            pill.hide(after: Self.errorAutoRecoverySeconds)
        }
    }

    private func showCriticalErrorAlert(for err: MurmurError) {
        // Murmur is LSUIElement (menu-bar only); without an explicit activate,
        // runModal() can appear behind the focused app or ignore the event.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = err.alertTitle
        alert.informativeText = err.errorDescription ?? ""
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
        state = .idle
        pill.hide()
    }

    private func showPermissionAlert(for permission: MurmurError.Permission) {
        let alert = NSAlert()
        alert.messageText = "\(permission.rawValue.capitalized) Permission Required"
        alert.informativeText = "Murmur needs \(permission.rawValue) access to work. Please grant it in System Settings."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            permissions.openAccessibilitySettings()
        }
        state = .idle
        pill.hide()
    }

    private func setupUndoAutoRecovery() {
        removeUndoMonitor()
        undoMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command),
                  event.keyCode == 0x06 /* Z */ else { return }
            Task { @MainActor in
                guard case .undoable = self.state else { return }
                try? await self.injection.undoLastInjection()
                self.removeUndoMonitor()
                self.transition(to: .idle)
                Self.log.info("Undo triggered via Cmd+Z")
            }
        }
        undoTimer?.cancel()
        undoTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.removeUndoMonitor()
            self.transition(to: .idle)
        }
    }

    private func removeUndoMonitor() {
        if let monitor = undoMonitor {
            NSEvent.removeMonitor(monitor)
            undoMonitor = nil
        }
    }

    private var autoDetectLanguageEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoDetectLanguage")
    }

    /// Async language resolution for the non-streaming path. When the user has
    /// enabled audio-based detection AND an LID service is available, runs the
    /// LID model on the recorded audio and trusts the result above
    /// `lidConfidenceThreshold` IFF the detected language is in Cohere's set.
    /// Otherwise falls back to the synchronous resolver (Picker value or
    /// input-source "auto" mapping).
    ///
    /// Streaming V3 intentionally does not call this — pre-roll LID would
    /// defeat its first-token latency target.
    func resolveTranscriptionLanguageAsync(audioURL: URL) async -> String {
        let fallback = resolveTranscriptionLanguage()
        guard autoDetectLanguageEnabled else { return fallback }
        guard let lid else {
            // User opted into detection but the LID model is not available.
            // Surface a non-blocking toast — plan deliberately avoids silent
            // fallback so the user can take action — and proceed with the
            // Picker value for this one transcription.
            Self.log.warning("LID enabled but model not loaded; using fallback=\(fallback, privacy: .public)")
            pill.show(state: .error(.transcriptionFailed("Language model not installed")))
            pill.hide(after: Self.errorAutoRecoverySeconds)
            return fallback
        }

        do {
            let result = try await lid.identify(audioURL: audioURL)
            let mapped = CohereLanguageMapping.map(result.code)
            Self.log.info("LID: detected=\(result.code, privacy: .public) confidence=\(String(format: "%.2f", result.confidence), privacy: .public) mapped=\(mapped ?? "nil", privacy: .public) threshold=\(String(format: "%.2f", Self.lidConfidenceThreshold), privacy: .public) fallback=\(fallback, privacy: .public)")

            if let mapped, result.confidence >= Self.lidConfidenceThreshold {
                return mapped
            }
            return fallback
        } catch MurmurError.silenceDetected {
            // Silence is a normal condition (accidental press, nothing said).
            // Fall through quietly — no pill error, no user action required.
            Self.log.info("LID: silent audio, using fallback=\(fallback, privacy: .public)")
            return fallback
        } catch {
            // LID model load/inference failure is never fatal to transcription;
            // log and fall back so the user still gets text in their picked
            // language.
            Self.log.error("LID inference failed, falling back to \(fallback, privacy: .public): \(String(describing: error), privacy: .public)")
            pill.show(state: .error(.transcriptionFailed("Language detection unavailable")))
            pill.hide(after: Self.errorAutoRecoverySeconds)
            return fallback
        }
    }

    /// Called by MurmurApp when the LID auxiliary model transitions out of .ready
    /// (deleted, corrupted). Posts a pill toast so the user knows their
    /// auto-detect preference was silently disabled.
    /// Only fires on a real transition (lid was non-nil before), not on initial
    /// subscription when the model was never downloaded.
    func notifyLIDModelDetached() {
        pill.show(state: .error(.transcriptionFailed("Auto-detect disabled — language model was removed")))
        pill.hide(after: 4)
    }

    /// When language is "auto", resolve to the active input method's language.
    /// e.g., Pinyin/Wubi → "zh", ABC/US → "en", Kotoeri → "ja"
    private func resolveTranscriptionLanguage() -> String {
        let stored = UserDefaults.standard.string(forKey: Self.transcriptionLanguageKey) ?? "auto"
        guard stored == "auto" else { return stored }

        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String],
           let primary = languages.first {
            // Map input source language codes to our supported codes
            let prefix = String(primary.prefix(2))
            switch prefix {
            case "zh": return "zh"
            case "ja": return "ja"
            case "ko": return "ko"
            case "fr": return "fr"
            case "de": return "de"
            case "es": return "es"
            case "pt": return "pt"
            case "it": return "it"
            case "vi": return "vi"
            case "ar": return "ar"
            default: return "en"
            }
        }
        return "en"
    }

    private func mapError(_ error: Error) -> MurmurError {
        if let murmurError = error as? MurmurError {
            return murmurError
        }
        return .transcriptionFailed(error.localizedDescription)
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: String,
        body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MurmurError.timeout(operation: operation)
            }
            guard let result = try await group.next() else {
                throw MurmurError.timeout(operation: operation)
            }
            group.cancelAll()
            return result
        }
    }
}

private extension AppState {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
    var isUndoable: Bool {
        if case .undoable = self { return true }
        return false
    }
}
