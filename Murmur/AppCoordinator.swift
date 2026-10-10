import SwiftUI
import Carbon
import Combine
import HotKey
import AVFoundation
import os

enum AppState: Equatable, Sendable {
    case idle
    case recording
    /// Recording with streaming on; the preview has `chunkCount` pieces of text.
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

    /// What the menu-bar item is called for VoiceOver. Its icon changes with
    /// the state; this says the same in words.
    var menuBarAccessibilityName: String {
        switch self {
        case .idle, .undoable: return "Murmur"
        case .recording, .streaming: return "Murmur, recording"
        case .transcribing: return "Murmur, transcribing"
        case .injecting: return "Murmur, inserting text"
        case .error(let err): return "Murmur, error: \(err.shortMessage)"
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
    /// diff when correction is on. nil `rawText` means "no correction diff
    /// to show."
    @Published private(set) var transcriptionHistory: [(text: String, rawText: String?, language: DetectedLanguage, date: Date)] = []

    private let maxHistoryCount = 20

    let hotkey: HotkeyService
    let audio: AudioService
    private(set) var transcription: any TranscriptionServiceProtocol
    let injection: TextInjectionService
    let permissions: PermissionsService
    let audioFeedback: AudioFeedbackService
    let pill: any PillControlling
    /// False in tests: a test must not take a system-wide key from the
    /// person who runs it. Events sent with `hotkey.emit` still arrive.
    private let registersGlobalHotkey: Bool

    /// The optional ASR error-correction step that runs on the transcribed
    /// text before it is inserted.
    let correctionStep = CorrectionStep()

    /// The correction engine in use; see `CorrectionStep`.
    var correction: (any TranscriptionCorrection)? {
        get { correctionStep.engine }
        set { correctionStep.engine = newValue }
    }

    func reconfigureCorrectionEngine() {
        correctionStep.reconfigure()
    }

    /// Language code for the post-processing rules, from the language the
    /// transcript is actually written in. Returns nil for `.unknown`.
    private static func languageCode(for detected: DetectedLanguage) -> String? {
        switch detected {
        case .english: return "en"
        case .chinese: return "zh"
        case .unknown: return nil
        }
    }

    // MARK: - V3 Streaming (feature-flag gated)

    private(set) var streamingCoordinator: StreamingTranscriptionCoordinator?

    private var isStreamingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "streamingInputEnabled")
    }

    /// Shows the streamed text while the user speaks. Only the final text is
    /// inserted, once, after recording stops.
    private let streamingPreview = StreamingPreviewController()

    /// Local-only session metrics sink. Nil disables recording entirely —
    /// tests leave it nil so no Application Support file is touched;
    /// `MurmurApp` wires the real recorder at launch.
    var metricsRecorder: SessionMetricsRecorder?

    /// How often streaming re-transcribes the growing audio window. Qwen3-ASR
    /// handles a full 12 s window in about a second and returns nothing for
    /// silence, so a one-second cadence keeps text a pass or two behind speech.
    private static let streamingPassIntervalSeconds = 1.0

    /// When true, skips accessibility check (for onboarding test where we show text in-app, not inject)
    var skipAccessibilityCheck = false

    /// Replaces the model and permission checks made before a recording
    /// starts. Nil in the app; tests set it so no real model, permission
    /// prompt or alert is involved.
    var startPreflightOverride: (() async -> MurmurError?)?

    /// Wire up (or tear down) the Silero VAD service. AudioService uses
    /// it to decide silence at stop time and to drive endpointing in
    /// later phases. Pass nil to revert to the legacy RMS gate.
    func setVadService(_ service: VadService?) {
        audio.setVad(service)
    }

    /// Default trailing silence for hands-free mode when the user hasn't
    /// adjusted the slider. 1.5 s comfortably exceeds normal speech
    /// pauses (commas land around 0.2-0.4 s, sentence ends 0.5-0.8 s)
    /// while still feeling responsive.
    static let defaultHandsFreeTrailingSilenceSeconds: Double = 1.5

    /// Apply a recording mode end-to-end: route hotkey events and
    /// configure audio's auto-stop behaviour. Call this from settings
    /// changes and at startup; it replaces direct `hotkey.setMode(_:)`.
    func applyRecordingMode(_ mode: RecordingMode) {
        hotkey.setMode(mode)
        switch mode {
        case .toggle, .hold:
            audio.setHandsFreeAutoStop(trailingSilenceSeconds: nil)
        case .handsFree:
            let stored = UserDefaults.standard.object(forKey: "handsFreeTrailingSilenceSeconds") as? Double
            let seconds = stored ?? Self.defaultHandsFreeTrailingSilenceSeconds
            audio.setHandsFreeAutoStop(trailingSilenceSeconds: seconds)
        }
    }

    /// Load the model while the user is still speaking, so that it is ready
    /// when the recording ends. Does nothing when it is already loaded.
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
    /// A hotkey press that arrived while a transcription was running: start
    /// recording when that transcription is delivered.
    private(set) var pendingRecording = false
    /// True from the moment the audio engine is asked to start until that
    /// call returns — which, for a start that timed out, is later than the
    /// error the user saw.
    private var audioStartInFlight = false
    private let undoWindow = UndoWindow()
    private var hotkeyTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.murmur.app", category: "coordinator")

    init(
        hotkey: HotkeyService = HotkeyService(),
        audio: AudioService = AudioService(),
        transcription: any TranscriptionServiceProtocol = Qwen3TranscriptionService(
            modelDirectory: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(ModelBackend.qwen3.modelSubdirectory)
        ),
        injection: TextInjectionService = TextInjectionService(),
        permissions: PermissionsService = PermissionsService(),
        audioFeedback: AudioFeedbackService = AudioFeedbackService(),
        pill: any PillControlling = FloatingPillController(),
        registersGlobalHotkey: Bool = true
    ) {
        self.registersGlobalHotkey = registersGlobalHotkey
        self.hotkey = hotkey
        self.audio = audio
        self.transcription = transcription
        self.injection = injection
        self.permissions = permissions
        self.audioFeedback = audioFeedback
        self.pill = pill
        self.streamingCoordinator = StreamingTranscriptionCoordinator(
            transcription: transcription
        )

        // Defer start to next run loop to ensure StateObject is fully initialized
        Task { @MainActor [weak self] in
            self?.start()
        }
    }

    private func start() {
        // Load saved recording mode
        let savedMode: RecordingMode = UserDefaults.standard.string(forKey: "recordingMode")
            .flatMap(RecordingMode.init(rawValue:)) ?? .toggle
        applyRecordingMode(savedMode)

        // Load saved hotkey or use default (right command)
        if registersGlobalHotkey {
            hotkey.register(trigger: HotkeyPreference.load())
        }

        hotkeyTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.hotkey.events {
                await self.handleHotkeyEvent(event)
            }
        }

        // Unload the model on sleep. Sleep is only posted on the workspace's
        // own notification center. The model is not loaded here or on wake:
        // it holds gigabytes, so it is loaded when a recording starts and the
        // engine releases it after a few idle minutes.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.transcription.unloadModel() }
        }

        Self.log.info("Coordinator started")
    }

    func stop() {
        hotkeyTask?.cancel()
        audioLevelTask?.cancel()
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
        // A hotkey press during the file transcription queued a recording.
        // Nothing drains the queue on this path, so drop it: left set, the
        // microphone would open by itself after the next dictation.
        if pendingRecording {
            pendingRecording = false
            hotkey.notifyRecordingStopped()
        }
        transition(to: .idle)
    }

    // MARK: - Event Handling

    private func handleHotkeyEvent(_ event: HotkeyEvent) async {
        switch event {
        case .startRecording:
            if let failure = await startPreflightFailure() {
                // The hotkey service already counts this press as a recording.
                hotkey.notifyRecordingStopped()
                handleError(failure)
                return
            }
            if state == .idle || state.isError || state.isUndoable {
                await startRecordingFlow()
            } else if state == .transcribing || state == .injecting {
                pendingRecording = true
                Self.log.info("Recording queued (current state: \(String(describing: self.state)))")
            }

        case .stopRecording:
            // The press that follows a queued recording takes it back.
            pendingRecording = false
            guard state == .recording else { return }
            await stopAndTranscribe()

        case .cancelRecording:
            pendingRecording = false
            guard state == .recording else { return }
            audio.onAutoStop = nil
            audio.detachStreamingAccumulator()
            streamingCoordinator?.cancelSession()
            streamingCoordinator?.resetToIdle()
            streamingPreview.hide()
            audio.cancelRecording()
            // No sound: user just pressed Escape; pill.hide() is the confirmation.
            pill.hide()
            transition(to: .idle)
        }
    }

    /// Why a recording cannot start right now, or nil when it can.
    private func startPreflightFailure() async -> MurmurError? {
        if let startPreflightOverride { return await startPreflightOverride() }
        // Without a downloaded model the streaming pipeline would silently
        // swallow transcription errors (processChunkBuffer logs and
        // continues; full-pass transitions to .done on failure). Catch it
        // here and surface a proper NSAlert before the user wastes a
        // recording on a session that can't produce text.
        guard Self.isActiveBackendModelInstalled else { return .modelNotFound }
        let status = permissions.checkAll()
        if status.microphone == .notDetermined {
            let granted = await permissions.requestMicrophone()
            if !granted { return .permissionRevoked(.microphone) }
        } else if status.microphone != .granted {
            return .permissionRevoked(.microphone)
        }
        if !skipAccessibilityCheck && status.accessibility != .granted {
            return .permissionRevoked(.accessibility)
        }
        return nil
    }

    private func startRecordingFlow() async {
        // The undo window of the previous dictation ends here; its timer
        // must not put a live recording back to idle.
        undoWindow.cancel()
        preloadModelInBackground()
        if isStreamingEnabled {
            await startStreamingRecordingFlow()
        } else {
            await startV1RecordingFlow()
        }
    }

    /// Start the audio engine, giving up after 5 s.
    ///
    /// A start that timed out is still running inside `AudioService`, which
    /// is not safe to enter twice. Until it returns, a new start is refused
    /// with the same timeout error.
    private func startAudioCapture() async throws {
        guard !audioStartInFlight else {
            throw MurmurError.timeout(operation: "start recording")
        }
        audioStartInFlight = true
        do {
            try await withTimeout(seconds: 5, operation: "start recording", onLateCompletion: { [weak self] _ in
                // The start outlived its timeout and the app has already
                // reported the failure. Release the engine.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.audio.cancelRecording()
                    self.audioStartInFlight = false
                }
            }) {
                try await self.audio.startRecording()
            }
            audioStartInFlight = false
        } catch {
            // After a timeout the call is still running; the late-completion
            // handler above clears the flag.
            if case .timeout? = error as? MurmurError {} else { audioStartInFlight = false }
            throw error
        }
    }

    /// Stop the audio engine and return the recording, giving up after 5 s.
    private func stopAudioCapture() async throws -> URL {
        try await withTimeout(seconds: 5, operation: "stop recording", onLateCompletion: { result in
            // Nobody is waiting for this recording any more.
            if case .success(let wav) = result {
                try? FileManager.default.removeItem(at: wav)
            }
        }) {
            try await self.audio.stopRecording()
        }
    }

    /// The one exit for a recording that did not start. `HotkeyService`
    /// counts the key press as a recording (and captures Escape) before the
    /// coordinator has decided anything, and `AudioService` may have installed
    /// its tap and created the file before it failed.
    private func abandonRecordingStart(after error: Error) {
        audioLevelTask?.cancel()
        audio.onAutoStop = nil
        hotkey.notifyRecordingStopped()
        // A start that timed out is still running inside AudioService;
        // `startAudioCapture` releases the engine when it returns.
        if case .timeout? = error as? MurmurError { return }
        audio.cancelRecording()
    }

    // MARK: - V1 Recording Flow (unchanged)

    private func startV1RecordingFlow() async {
        do {
            transition(to: .recording)
            audioFeedback.playStartRecording()
            let cancelHandler: () -> Void = { [weak self] in self?.hotkey.emit(.cancelRecording) }
            pill.show(state: .recording, audioLevel: 0, onCancel: cancelHandler)

            // Monitor audio levels for the pill
            audioLevelTask?.cancel()
            audioLevelTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await level in self.audio.audioLevel {
                    self.currentAudioLevel = level
                    self.pill.show(state: .recording, audioLevel: level, onCancel: cancelHandler)
                }
            }

            // Wire the auto-stop callback BEFORE startRecording so a
            // very-fast hands-free / max-duration trigger still has a
            // consumer. Set on every flow start; cleared on stop/cancel.
            audio.onAutoStop = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.state == .recording else { return }
                    Self.log.info("Auto-stop fired (V1)")
                    // Sync HotkeyService.isRecording so the next hotkey
                    // press starts a new recording — without this, the
                    // hotkey thinks we're still recording and the next
                    // press emits .stopRecording (a no-op).
                    self.hotkey.notifyRecordingStopped()
                    await self.stopAndTranscribe()
                }
            }

            try await startAudioCapture()
        } catch {
            abandonRecordingStart(after: error)
            audioFeedback.playError()
            transition(to: .error(mapError(error)))
        }
    }

    // MARK: - V3 Streaming Recording Flow

    private var streamingAccumulator: AudioBufferAccumulator?

    private func startStreamingRecordingFlow() async {
        do {
            let lang = spokenLanguagesHint()

            transition(to: .recording)
            audioFeedback.playStartRecording()
            let cancelHandler: () -> Void = { [weak self] in self?.hotkey.emit(.cancelRecording) }
            pill.show(state: .streaming(chunkCount: 0), audioLevel: 0, onCancel: cancelHandler)

            audioLevelTask?.cancel()
            audioLevelTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await level in self.audio.audioLevel {
                    self.currentAudioLevel = level
                    // Pill update happens via streamingCoordinator published state
                    if case .streaming(let n) = self.streamingCoordinator?.sessionState {
                        self.pill.show(state: .streaming(chunkCount: n), audioLevel: level, onCancel: cancelHandler)
                    }
                }
            }

            audio.onAutoStop = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.state == .recording else { return }
                    Self.log.info("Auto-stop fired (streaming)")
                    self.hotkey.notifyRecordingStopped()
                    await self.stopAndTranscribeStreaming()
                }
            }

            try await startAudioCapture()

            let wavURL = audio.currentRecordingURL ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("murmur_stream_\(UUID().uuidString).wav")

            let acc = streamingCoordinator?.beginSession(
                language: lang,
                fullWavURL: wavURL,
                incrementalSeconds: Self.streamingPassIntervalSeconds,
                onPreviewText: { [weak self] text in self?.streamingPreview.update(text) }
            )
            streamingAccumulator = acc

            // Attach accumulator to audio tap via AudioService dual-output extension
            audio.attachStreamingAccumulator(acc)
        } catch {
            abandonRecordingStart(after: error)
            streamingCoordinator?.cancelSession()
            streamingCoordinator?.resetToIdle()
            streamingPreview.hide()
            audioFeedback.playError()
            transition(to: .error(mapError(error)))
        }
    }

    private func stopAndTranscribeStreaming() async {
        // Stop-to-final-text clock starts the moment the user stops speaking.
        let stopRequestedAt = Date()
        audioLevelTask?.cancel()
        audio.onAutoStop = nil
        // No stop sound: release is user-initiated, already known to the user.
        // Pill transitions ("Listening..." → "Transcribing...") provide visual
        // confirmation; V1 success chime still confirms the system event of
        // transcription completing.

        audio.detachStreamingAccumulator()

        var recordedWav: URL?
        do {
            transition(to: .transcribing)
            pill.show(state: .transcribing)

            let wav = try await stopAudioCapture()
            recordedWav = wav

            // Pass the full WAV URL to the coordinator for the full-pass
            streamingCoordinator?.updateFullWavURL(wav)
            streamingCoordinator?.endSession()

            // Wait for coordinator to reach done/cancelled/failed
            await streamingCoordinator?.waitUntilEnded()
            streamingPreview.hide()

            // Check how the session ended and show appropriate feedback.
            var outcome = streamingOutcome()
            switch streamingCoordinator?.cancellationReason {
            case .backstopTimeout:
                handleError(.timeout(operation: "Streaming"))
            case .user:
                transition(to: .idle)
                pill.hide(after: 0.5)
            case nil:
                guard let final = streamingCoordinator?.finalResult else {
                    transition(to: .idle)
                    pill.hide(after: 1)
                    break
                }
                // Nothing has been typed yet. Run the same post-processing
                // as V1 and insert the final text once.
                let language = final.language == .unknown
                    ? Qwen3TranscriptionService.detectLanguage(final.text) : final.language
                let delivered = try await deliverTranscription(
                    TranscriptionResult(text: final.text, language: language, durationMs: final.durationMs)
                )
                if !delivered {
                    // Empty because the final pass broke, not because nothing
                    // was said: say so instead of quietly hiding the pill.
                    if streamingCoordinator?.fullPassFailed == true {
                        throw MurmurError.transcriptionFailed("Final transcription pass failed")
                    }
                    outcome = .silenceGated
                }
            }

            recordStreamingMetrics(outcome: outcome, stopRequestedAt: stopRequestedAt)
        } catch {
            streamingCoordinator?.cancelSession()
            streamingPreview.hide()
            recordStreamingMetrics(
                outcome: Self.failureOutcome(for: error), stopRequestedAt: stopRequestedAt
            )
            handleError(mapError(error))
        }

        // The session has ended (done, cancelled or failed), so nothing needs
        // the recording of the user's voice any more.
        if let recordedWav {
            try? FileManager.default.removeItem(at: recordedWav)
        }

        // Reset coordinator so next session can begin
        streamingCoordinator?.resetToIdle()

        if pendingRecording {
            pendingRecording = false
            await startRecordingFlow()
        }
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
        let stopRequestedAt = Date()
        audioLevelTask?.cancel()
        audio.onAutoStop = nil
        // No stop sound: release is user-initiated. Success chime on inject
        // confirms the system event once transcription finishes.

        do {
            transition(to: .transcribing)
            pill.show(state: .transcribing)

            let wav = try await stopAudioCapture()
            // The model detects the spoken language itself; the user's
            // "Languages you speak" only tell it which scripts to expect.
            let (result, delivered) = try await transcribeAndDeliver(wav: wav, hint: spokenLanguagesHint())

            // Increment V1 usage counter for discovery badge
            if delivered { V1UsageCounter.increment() }

            recordSessionMetrics(SessionMetrics(
                date: Date(),
                mode: .v1FullPass,
                outcome: delivered ? .injected : .silenceGated,
                language: Self.metricsLanguage(for: result.language),
                stopToFinalTextMs: Self.elapsedMs(since: stopRequestedAt)
            ))
        } catch {
            recordSessionMetrics(SessionMetrics(
                date: Date(),
                mode: .v1FullPass,
                outcome: Self.failureOutcome(for: error),
                language: Self.metricsLanguage(for: nil),
                stopToFinalTextMs: Self.elapsedMs(since: stopRequestedAt)
            ))
            handleError(mapError(error))
        }

        // Drain pending recording
        if pendingRecording {
            pendingRecording = false
            await startRecordingFlow()
        }
    }

    /// Replaces the real paste when delivering a transcription (tests only).
    typealias PasteOverride = @Sendable (String) async throws -> InjectionMethod

    /// Transcribe a finished recording and deliver the text. Returns the
    /// transcription and whether any text was inserted.
    ///
    /// The WAV holds the user's voice, so it is deleted as soon as the engine
    /// is done with it — also when the engine failed or outlived the timeout.
    private func transcribeAndDeliver(
        wav: URL,
        hint: String,
        paste: PasteOverride? = nil
    ) async throws -> (TranscriptionResult, Bool) {
        let result = try await withTimeout(seconds: 120, operation: "transcription") { () async throws -> TranscriptionResult in
            defer { try? FileManager.default.removeItem(at: wav) }
            return try await self.transcription.transcribe(audioURL: wav, language: hint)
        }
        let delivered = try await deliverTranscription(result, paste: paste)
        return (result, delivered)
    }

    // MARK: - Session metrics

    /// A silence-gated recording is recorded as its own outcome rather than a
    /// failure: a rising count is the dropped-utterance class of bug. A
    /// recording that transcribed to nothing is counted with it.
    private static func failureOutcome(for error: Error) -> SessionMetrics.Outcome {
        if case .silenceDetected? = error as? MurmurError { return .silenceGated }
        return .failed
    }

    /// Map how the streaming session ended onto a metrics outcome.
    private func streamingOutcome() -> SessionMetrics.Outcome {
        switch streamingCoordinator?.cancellationReason {
        case .backstopTimeout: return .failed
        case .user: return .cancelled
        case nil: return .injected
        }
    }

    /// Snapshot the streaming coordinator's measurements for this session.
    /// Must run BEFORE `resetToIdle()` clears them.
    private func recordStreamingMetrics(outcome: SessionMetrics.Outcome, stopRequestedAt: Date) {
        let coord = streamingCoordinator
        recordSessionMetrics(SessionMetrics(
            date: Date(),
            mode: .v3Streaming,
            outcome: outcome,
            language: Self.metricsLanguage(for: coord?.finalResult?.language),
            stopToFinalTextMs: Self.elapsedMs(since: stopRequestedAt),
            timeToFirstWordMs: coord?.timeToFirstWordMs,
            finalizeLatencyMs: coord?.finalizingStartedAt.map(Self.elapsedMs(since:)),
            editDistanceRatio: coord?.lastEditDistanceRatio,
            cpuFallback: coord?.didTriggerCPUFallback ?? false,
            chunkCount: coord?.chunkCount
        ))
    }

    /// Persist one session's measurements. Never throws and never blocks the
    /// dictation flow — metrics are diagnostics, not part of the product path.
    private func recordSessionMetrics(_ metrics: SessionMetrics) {
        guard let metricsRecorder else { return }
        Task.detached(priority: .utility) {
            metricsRecorder.record(metrics)
        }
    }

    static func elapsedMs(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    /// Post-process a finished transcription, insert it at the cursor, record
    /// it in history and show the "Inserted" pill. Shared by the V1 full-pass
    /// path and streaming sessions, which both insert the text once.
    ///
    /// Returns false, and inserts and records nothing, when there is no text:
    /// pasting an empty string would replace the user's selection with
    /// nothing under an "Inserted" pill.
    @discardableResult
    private func deliverTranscription(
        _ result: TranscriptionResult,
        paste: PasteOverride? = nil
    ) async throws -> Bool {
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Self.log.info("Empty transcription: nothing to insert")
            transition(to: .idle)
            pill.hide(after: 0.5)
            return false
        }

        // The correction prompt is language-specific and exists for Chinese
        // and English, chosen by what the transcript is actually written in.
        // Any other language gets a code it does not know.
        let lang = Self.languageCode(for: result.language) ?? "und"

        // Pipeline: transcribe → correction (LLM, 2.5 s cap) → inject. The
        // correction step silently falls back to its input on timeout or error.
        let rawTranscribed = result.text
        let textToInject = await correctionStep.apply(to: rawTranscribed, language: lang)

        transition(to: .injecting)
        pill.show(state: .injecting)

        let method = try await withTimeout(seconds: 5, operation: "text injection") { () async throws -> InjectionMethod in
            if let paste { return try await paste(textToInject) }
            return try await self.injection.inject(text: textToInject)
        }

        lastTranscription = textToInject
        lastLanguage = result.language
        // History records the injected (final) text. `rawText` captures the
        // transcription as the model produced it whenever correction changed
        // it, so Recent can show what was altered.
        let rawForHistory: String? = (textToInject != rawTranscribed) ? rawTranscribed : nil
        transcriptionHistory.insert((text: textToInject, rawText: rawForHistory, language: result.language, date: Date()), at: 0)
        if transcriptionHistory.count > maxHistoryCount {
            transcriptionHistory.removeLast()
        }

        let undoableState = AppState.undoable(text: textToInject, method: method)
        transition(to: undoableState)
        // No success chime: user can see the text appear in their editor
        // and the "Inserted" pill confirms it. A sound is redundant. Error
        // path still plays error sound because failures have no visual
        // equivalent.
        pill.show(state: undoableState)
        pill.hide(after: 2)
        // Undo timer + Cmd+Z monitor set up automatically by transition(to: .undoable)
        return true
    }

#if DEBUG
    /// Testable entry-point that bypasses audio I/O. Runs the real transcribe →
    /// correction → deliver pipeline on a pre-recorded WAV; only the
    /// paste into the frontmost app is replaced by `paste`.
    func stopAndTranscribeV1ForTesting(
        wav: URL,
        lang: String,
        paste: @escaping PasteOverride = { _ in .clipboard }
    ) async {
        do {
            _ = try await transcribeAndDeliver(wav: wav, hint: lang, paste: paste)
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

    /// Fast readiness check — is a manifest.json (the "download + verify
    /// completed" marker) present on disk for the speech model? Used by the
    /// startRecording pre-check to avoid wasting a recording session when no
    /// model is installed.
    private static var isActiveBackendModelInstalled: Bool {
        let manifestURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ModelBackend.qwen3.modelSubdirectory)
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
        ErrorAlerts.showCritical(err)
        state = .idle
        pill.hide()
    }

    private func showPermissionAlert(for permission: MurmurError.Permission) {
        if ErrorAlerts.askToOpenSettings(for: permission) {
            permissions.openAccessibilitySettings()
        }
        state = .idle
        pill.hide()
    }

    private func setupUndoAutoRecovery() {
        undoWindow.open(
            onUndoSeen: { [weak self] in
                guard let self, case .undoable = self.state else { return }
                self.undoWindow.cancel()
                self.transition(to: .idle)
                Self.log.info("Undo seen (Cmd+Z)")
            },
            onExpire: { [weak self] in
                // Only leave the undo window. If a recording started meanwhile,
                // going idle here would strand a running engine.
                guard let self, case .undoable = self.state else { return }
                self.transition(to: .idle)
            }
        )
    }

    /// The user's "Languages you speak" as the engine's language hint.
    private func spokenLanguagesHint() -> String {
        SpokenLanguages.hint(for: SpokenLanguages.current())
    }

    /// Language recorded with a session's metrics: what the transcript was
    /// written in when that is known, "und" otherwise.
    private static func metricsLanguage(for detected: DetectedLanguage?) -> String {
        detected.flatMap(languageCode(for:)) ?? "und"
    }

    private func mapError(_ error: Error) -> MurmurError {
        if let murmurError = error as? MurmurError {
            return murmurError
        }
        return .transcriptionFailed(error.localizedDescription)
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
