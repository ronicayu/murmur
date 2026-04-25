import SwiftUI
import Carbon
import Combine
import HotKey
import AVFoundation
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

    /// Legacy slot — Whisper-tiny LID was removed in favour of Cohere-echo
    /// (see `transcribeWithAutoDetectIfNeeded`). Kept to avoid breaking the
    /// public surface during the deprecation window. Always nil at runtime.
    /// TODO(v0.4): delete when no external code references it.
    var lid: Any? = nil

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

    /// Map a post-hoc text-based `DetectedLanguage` (what Cohere actually
    /// produced) back to a Cohere language code. Returns nil for `.unknown` —
    /// caller should keep the current language hint.
    private static func cohereCode(for detected: DetectedLanguage) -> String? {
        switch detected {
        case .english: return "en"
        case .chinese: return "zh"
        case .unknown: return nil
        }
    }

    // MARK: - V3 Streaming (feature-flag gated)

    private(set) var streamingCoordinator: StreamingTranscriptionCoordinator?

    /// Set by MurmurApp at construction time; the coordinator queries the
    /// router via this manager.
    weak var modelManager: ModelManager?

    /// FireRed transcription service. Lazily created when first needed AND
    /// when the FireRed model is downloaded. nil until either condition fails.
    /// Replaced when the model directory changes (for tests via __testing seams).
    private var fireRed: FireRedTranscriptionService?
    private var fireRedModelDirectory: URL?

    /// True after we've logged the first FireRed failure this session — keeps
    /// the log readable when the model is missing or broken.
    private var hasLoggedFireRedFailureThisSession = false

    /// CT-Transformer punctuation service. Active when the user has enabled
    /// the ASR-punctuation toggle AND the aux model is on disk. nil otherwise.
    private var asrPunc: ASRPunctuationService?

    /// Suppress repeat punc-failure logs the same way as FireRed.
    private var hasLoggedASRPuncFailureThisSession = false

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

    /// Wire up (or tear down) the FireRed service. Called from `MurmurApp` in
    /// response to `committedUseFireRedChange` and `committedBackendChange`.
    /// Passing `nil` releases the recognizer.
    func setFireRedService(_ service: FireRedTranscriptionService?, modelDirectory: URL?) {
        self.fireRed = service
        self.fireRedModelDirectory = modelDirectory
        self.hasLoggedFireRedFailureThisSession = false
    }

    /// Wire up (or tear down) the ASR-punctuation service. Called from
    /// `MurmurApp` in response to `committedUseASRPunctuationChange`.
    /// Passing `nil` releases the recognizer.
    func setASRPunctuationService(_ service: ASRPunctuationService?) {
        self.asrPunc = service
        self.hasLoggedASRPuncFailureThisSession = false
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

            // For long uploads we keep things simple: trust the IME / picker
            // language. Auto-detect-by-retry would mean transcribing the whole
            // file twice on a mismatch, which is too costly for long audio.
            let lang = self.resolveTranscriptionLanguage()

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
            // Initial guess from the IME / Settings picker. When auto-detect is
            // on we may end up re-transcribing if Cohere reports a different
            // language for the output text — see transcribeWithAutoDetectIfNeeded.
            let initialLang = resolveTranscriptionLanguage()
            let result = try await transcribeWithAutoDetectIfNeeded(wav: wav, initialLang: initialLang)
            // The "actual" language used for this transcription, post-retry.
            let lang = Self.cohereCode(for: result.language) ?? initialLang

            // Pipeline: transcribe → ASR-punc (CT-Transformer, ~1 ms) → correction (LLM, 2.5 s cap)
            // → cleanup (rules, 250 ms cap) → inject. Each step silently falls back to its input on
            // timeout or error.
            let rawTranscribed = result.text
            let punctuated = await applyASRPunctuationIfEnabled(text: rawTranscribed, language: lang)
            let corrected = await applyCorrectionIfEnabled(text: punctuated, language: lang)
            let textToInject = await applyCleanupIfEnabled(text: corrected, language: lang)

            transition(to: .injecting)
            pill.show(state: .injecting)

            let method = try await withTimeout(seconds: 5, operation: "text injection") {
                try await self.injection.inject(text: textToInject)
            }

            lastTranscription = textToInject
            lastLanguage = result.language
            // History records the injected (final) text. `rawText` captures
            // the pre-pipeline transcription whenever ANY post-processing
            // step (LLM correction OR rule-based cleanup) changed the text.
            // Comparing against the final injected text — not just the
            // correction step — means cleanup-only diffs (e.g. just adding
            // a terminal `。`) also surface in Recent, so the user can
            // always tell whether the pipeline did anything to their words.
            let rawForHistory: String? = (textToInject != rawTranscribed) ? rawTranscribed : nil
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

    /// Runs the CT-Transformer punctuation model on the bare ASR transcript
    /// if the toggle is ON and the service is wired in. Pure additive: the
    /// model only inserts ，。？！ and never paraphrases, so we don't apply
    /// the LLM safety rails here. Silent fallback to `rawText` on any throw.
    ///
    /// Decides whether to run based on text content (`looksChineseEnough`),
    /// NOT the `language` parameter. The IME-derived language can be wrong
    /// (English IME + Chinese speech is common), and Cohere/FireRed both
    /// faithfully produce CJK chars from Chinese audio regardless of the
    /// input hint. The CT-Transformer trained on zh-en data would otherwise
    /// append a Chinese 。 to pure-English text — see spike at
    /// ~/work/firered-spike/run_punc.py case 4.
    private func applyASRPunctuationIfEnabled(text rawText: String, language: String) async -> String {
        guard let svc = asrPunc else { return rawText }
        guard Self.looksChineseEnough(rawText) else { return rawText }
        let punctuated = await svc.addPunctuation(to: rawText)
        if !hasLoggedASRPuncFailureThisSession && punctuated.isEmpty && !rawText.isEmpty {
            hasLoggedASRPuncFailureThisSession = true
            Self.log.warning("ASR punctuation returned empty for non-empty input; falling back to raw")
            return rawText
        }
        return punctuated.isEmpty ? rawText : punctuated
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
            let punctuated = await applyASRPunctuationIfEnabled(text: rawTranscribed, language: lang)
            let corrected = await applyCorrectionIfEnabled(text: punctuated, language: lang)
            let textToInject = await applyCleanupIfEnabled(text: corrected, language: lang)

            // Skip real injection in tests — just record what would be injected.
            lastTranscription = textToInject
            lastLanguage = result.language
            // Capture rawText whenever the pipeline touched the words (matches production).
            let rawForHistory: String? = (textToInject != rawTranscribed) ? rawTranscribed : nil
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

    /// V1 transcribe path that consults `TranscriptionRouter` and dispatches to
    /// either FireRed or the existing transcription service. On FireRed errors
    /// we fall back to Cohere for THIS request only and log the failure once
    /// per session.
    private func routedTranscribeV1(wav: URL, language: String) async throws -> TranscriptionResult {
        let mm = self.modelManager
        let choice = TranscriptionRouter.route(
            activeBackend: mm?.activeBackend ?? .onnx,
            useFireRedForChinese: mm?.useFireRedForChinese ?? false,
            language: language,
            version: .v1FullPass
        )

        switch choice {
        case .fireRed:
            guard let svc = fireRed else {
                Self.log.warning("FireRed routing chosen but service not initialised — falling back to Cohere")
                return try await transcription.transcribe(audioURL: wav, language: language)
            }
            do {
                let samples = try Self.loadSamples16k(url: wav)
                let text = try await svc.transcribe(samples: samples, sampleRate: 16000)
                // Tag the result by content, NOT by the input language hint —
                // a user with an English IME can still speak Chinese, and FireRed
                // will faithfully transcribe Chinese characters. Echoing the input
                // hint here would lie to the auto-detect retry path AND make the
                // ASR-punc guard skip Chinese text. Mirrors NativeTranscriptionService's
                // detectLanguage(_:) heuristic (CJK-char ratio > 30%).
                let lang: DetectedLanguage = Self.detectLanguageFromText(text)
                return TranscriptionResult(text: text, language: lang, durationMs: 0)
            } catch {
                if !hasLoggedFireRedFailureThisSession {
                    hasLoggedFireRedFailureThisSession = true
                    Self.log.warning("FireRed inference failed (further failures suppressed this session): \(String(describing: error), privacy: .public)")
                }
                return try await transcription.transcribe(audioURL: wav, language: language)
            }

        case .cohereONNX, .cohereStreaming, .existing:
            // Existing path — the active service is already correct because
            // MurmurApp swaps it on backend changes.
            return try await transcription.transcribe(audioURL: wav, language: language)
        }
    }

    /// Transcribe with optional Cohere-echo auto-detect. Replaces the old
    /// pre-flight Whisper-tiny LID step.
    ///
    /// Flow:
    /// 1. Transcribe once with `initialLang` (the IME guess or Settings picker).
    /// 2. If `autoDetectLanguage` is on and the post-hoc text-based language
    ///    on the result differs from `initialLang`, the constraint was wrong
    ///    — re-transcribe with the detected language.
    /// 3. Otherwise return the first result.
    ///
    /// Cost: zero extra latency when the IME guess was right; one extra
    /// transcription pass when it was wrong. Encoder dominates pass cost so
    /// the retry is roughly 1× the base latency, not negligible — but only
    /// fires on the rare cases that previously produced garbage output.
    ///
    /// Updates `activeBadge` if the language changed so the pill reflects
    /// what the user is actually getting.
    private func transcribeWithAutoDetectIfNeeded(
        wav: URL,
        initialLang: String
    ) async throws -> TranscriptionResult {
        let result1 = try await withTimeout(seconds: 120, operation: "transcription") {
            try await self.routedTranscribeV1(wav: wav, language: initialLang)
        }
        guard autoDetectLanguageEnabled else { return result1 }

        // `result1.language` is what the transcription engine reports based on
        // the OUTPUT TEXT (`NativeTranscriptionService.detectLanguage`). When
        // it disagrees with the constrained input language, that's the signal
        // that the constraint was wrong.
        guard let detectedCode = Self.cohereCode(for: result1.language),
              detectedCode != initialLang else {
            Self.log.info("auto-detect: initialLang=\(initialLang, privacy: .public) matched \(String(describing: result1.language), privacy: .public) — no retry")
            return result1
        }

        Self.log.info("auto-detect: initialLang=\(initialLang, privacy: .public) → detected=\(detectedCode, privacy: .public); re-transcribing")

        // Visibly update the badge during the retry so the user sees the
        // correction in flight (e.g. EN· → ZH·).
        let storedSetting = UserDefaults.standard.string(forKey: Self.transcriptionLanguageKey) ?? "auto"
        let updatedBadge = LanguageBadge.badgeText(resolvedCode: detectedCode, storedSetting: storedSetting)
        if updatedBadge != activeBadge {
            activeBadge = updatedBadge
            pill.show(state: .transcribing, languageBadge: activeBadge)
        }

        do {
            let result2 = try await withTimeout(seconds: 120, operation: "transcription-retry") {
                try await self.routedTranscribeV1(wav: wav, language: detectedCode)
            }
            return result2
        } catch {
            Self.log.warning("auto-detect retry failed, using first result: \(String(describing: error), privacy: .public)")
            return result1
        }
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

    /// Load 16 kHz mono Float32 samples from a wav. Mirrors
    /// NativeTranscriptionService.loadAudio for the same conversion semantics.
    /// Decide whether a transcript is "Chinese-ish" enough to deserve the
    /// CT-Transformer ASR punctuation pass. Looks at content, NOT at the
    /// language hint or IME, because the hint may have been wrong (English
    /// IME with Chinese speech is a real and common case). The CT-Transformer
    /// is trained on zh-en specifically, so we also bail when the text
    /// contains hiragana / katakana — Japanese-only text would otherwise get
    /// a Chinese 。 appended.
    fileprivate static func looksChineseEnough(_ text: String) -> Bool {
        var hasCJK = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) {
                return false  // Japanese hiragana / katakana detected — skip
            }
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                hasCJK = true
            }
        }
        return hasCJK
    }

    /// Content-based language detection, used to tag FireRed transcripts
    /// because FireRed itself doesn't return a language. Mirrors
    /// NativeTranscriptionService.detectLanguage(_:): if Chinese characters
    /// make up >30% of the alphabetic chars, call it Chinese.
    fileprivate static func detectLanguageFromText(_ text: String) -> DetectedLanguage {
        let chineseChars = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let totalAlpha = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if totalAlpha > 0 && Double(chineseChars) / Double(totalAlpha) > 0.3 {
            return .chinese
        }
        return .english
    }

    fileprivate static func loadSamples16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        if srcFormat.sampleRate == 16000 && srcFormat.channelCount == 1
            && srcFormat.commonFormat == .pcmFormatFloat32 {
            let frameCount = AVAudioFrameCount(file.length)
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
                throw MurmurError.transcriptionFailed("Failed to create audio buffer")
            }
            try file.read(into: buf)
            guard let data = buf.floatChannelData?[0] else {
                throw MurmurError.transcriptionFailed("No audio data")
            }
            return Array(UnsafeBufferPointer(start: data, count: Int(buf.frameLength)))
        }

        guard let conv = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw MurmurError.transcriptionFailed("Cannot create audio converter")
        }
        let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: 4096)!
        var allSamples = [Float]()
        var convError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            do {
                inBuf.frameLength = 0
                try file.read(into: inBuf)
                if inBuf.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuf
            } catch { outStatus.pointee = .endOfStream; return nil }
        }
        var status: AVAudioConverterOutputStatus
        repeat {
            let chunk = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096)!
            status = conv.convert(to: chunk, error: &convError, withInputFrom: inputBlock)
            if let data = chunk.floatChannelData?[0], chunk.frameLength > 0 {
                allSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(chunk.frameLength)))
            }
        } while status == .haveData
        if allSamples.isEmpty {
            throw MurmurError.transcriptionFailed("No audio data after conversion")
        }
        return allSamples
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
