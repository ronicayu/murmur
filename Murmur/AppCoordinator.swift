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
        case .streaming(let n): return n == 0 ? "Streaming..." : "Streaming... (\(n) chunks)"
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
    @Published private(set) var transcriptionHistory: [(text: String, language: DetectedLanguage, date: Date)] = []

    private let maxHistoryCount = 20

    let hotkey: HotkeyService
    let audio: AudioService
    let transcription: TranscriptionService
    let injection: TextInjectionService
    let permissions: PermissionsService
    let audioFeedback: AudioFeedbackService
    let pill: FloatingPillController

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
                    Self.log.warning("Model preload failed (will retry on first use): \(error)")
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
    private static let log = Logger(subsystem: "com.murmur.app", category: "coordinator")

    init(
        hotkey: HotkeyService = HotkeyService(),
        audio: AudioService = AudioService(),
        transcription: TranscriptionService = TranscriptionService(),
        injection: TextInjectionService = TextInjectionService(),
        permissions: PermissionsService = PermissionsService(),
        audioFeedback: AudioFeedbackService = AudioFeedbackService(),
        pill: FloatingPillController = FloatingPillController()
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
                self.transcriptionHistory.insert(
                    (text: result.text, language: result.language, date: Date()), at: 0
                )
                if self.transcriptionHistory.count > self.maxHistoryCount {
                    self.transcriptionHistory.removeLast()
                }

                let undoableState = AppState.undoable(text: result.text, method: method)
                self.transition(to: undoableState)
                self.audioFeedback.playSuccess()
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
                let err = self.mapError(error)
                self.transition(to: .error(err))
                self.audioFeedback.playError()
                self.pill.show(state: .error(err))
                self.pill.hide(after: 2)
            }
        }
    }

    // MARK: - Event Handling

    private func handleHotkeyEvent(_ event: HotkeyEvent) async {
        switch event {
        case .startRecording:
            let status = permissions.checkAll()
            if status.microphone != .granted {
                transition(to: .error(.permissionRevoked(.microphone)))
                return
            }
            if !skipAccessibilityCheck && status.accessibility != .granted {
                transition(to: .error(.permissionRevoked(.accessibility)))
                return
            }
            if state == .idle || state.isError {
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
            audio.cancelRecording()
            audioFeedback.playStopRecording()
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
            transition(to: .recording)
            audioFeedback.playStartRecording()
            pill.show(state: .recording, audioLevel: 0)

            // Monitor audio levels for the pill
            audioLevelTask?.cancel()
            audioLevelTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await level in self.audio.audioLevel {
                    self.currentAudioLevel = level
                    self.pill.show(state: .recording, audioLevel: level)
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
            transition(to: .recording)
            audioFeedback.playStartRecording()
            pill.show(state: .streaming(chunkCount: 0), audioLevel: 0)

            audioLevelTask?.cancel()
            audioLevelTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await level in self.audio.audioLevel {
                    self.currentAudioLevel = level
                    // Pill update happens via streamingCoordinator published state
                    if case .streaming(let n) = self.streamingCoordinator?.sessionState {
                        self.pill.show(state: .streaming(chunkCount: n), audioLevel: level)
                    }
                }
            }

            try await withTimeout(seconds: 5, operation: "start recording") {
                try await self.audio.startRecording()
            }

            // Resolve insertion point before any text is injected
            let startOffset = resolveCurrentCursorOffset()
            let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            let lang = resolveTranscriptionLanguage()
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
        audioFeedback.playStopRecording()

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

            // UT-P0-2: If full-pass replaced streamed text, show undoable state so user
            // knows text was refined and can Cmd+Z to revert.
            if let replacedText = streamingCoordinator?.fullPassReplacedText {
                let undoableState = AppState.undoable(text: replacedText, method: .accessibility)
                transition(to: undoableState)
                audioFeedback.playSuccess()
                pill.show(state: undoableState)
                pill.hide(after: 3)
            } else {
                transition(to: .idle)
                audioFeedback.playSuccess()
                pill.hide(after: 1)
            }

        } catch {
            streamingCoordinator?.cancelSession()
            let err = mapError(error)
            transition(to: .error(err))
            audioFeedback.playError()
            pill.show(state: .error(err))
            pill.hide(after: 2)
        }

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
                await MainActor.run { coordinator.cancelSession() }
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
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return 0 }
        let axApp = AXUIElementCreateApplication(frontmost.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return 0 }
        let element = focused as! AXUIElement  // swiftlint:disable:this force_cast
        var selRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRef) == .success,
              let selValue = selRef else { return 0 }
        var cfRange = CFRange()
        guard AXValueGetValue(selValue as! AXValue, .cfRange, &cfRange) else { return 0 }  // swiftlint:disable:this force_cast
        return cfRange.location + cfRange.length
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
        audioFeedback.playStopRecording()

        do {
            transition(to: .transcribing)
            pill.show(state: .transcribing)

            let wav = try await withTimeout(seconds: 5, operation: "stop recording") {
                try await self.audio.stopRecording()
            }
            let lang = resolveTranscriptionLanguage()
            let result = try await withTimeout(seconds: 120, operation: "transcription") {
                return try await self.transcription.transcribe(audioURL: wav, language: lang)
            }

            transition(to: .injecting)
            pill.show(state: .injecting)

            let method = try await withTimeout(seconds: 5, operation: "text injection") {
                try await self.injection.inject(text: result.text)
            }

            lastTranscription = result.text
            lastLanguage = result.language
            transcriptionHistory.insert((text: result.text, language: result.language, date: Date()), at: 0)
            if transcriptionHistory.count > maxHistoryCount {
                transcriptionHistory.removeLast()
            }

            // Increment V1 usage counter for discovery badge
            V1UsageCounter.increment()

            let undoableState = AppState.undoable(text: result.text, method: method)
            transition(to: undoableState)
            audioFeedback.playSuccess()
            pill.show(state: undoableState)
            pill.hide(after: 2)

            // M4: Wire Cmd+Z undo during undoable window
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

            // Auto-transition from undoable to idle after 5s
            undoTimer?.cancel()
            undoTimer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.removeUndoMonitor()
                self.transition(to: .idle)
            }
        } catch {
            let err = mapError(error)
            transition(to: .error(err))
            audioFeedback.playError()
            pill.show(state: .error(err))
            pill.hide(after: 2)
        }

        // Drain pending recording
        if pendingRecording {
            pendingRecording = false
            await startRecordingFlow()
        }
    }

    // MARK: - Helpers

    private func transition(to newState: AppState) {
        let old = state
        state = newState
        Self.log.info("State: \(String(describing: old)) → \(String(describing: newState))")

        // Permission errors show a blocking alert; other errors auto-recover
        if case .error(let err) = newState {
            if case .permissionRevoked(let perm) = err {
                showPermissionAlert(for: perm)
            } else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    if case .error = self.state {
                        self.state = .idle
                        self.pill.hide()
                    }
                }
            }
        }
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

    private func removeUndoMonitor() {
        if let monitor = undoMonitor {
            NSEvent.removeMonitor(monitor)
            undoMonitor = nil
        }
    }

    /// When language is "auto", resolve to the active input method's language.
    /// e.g., Pinyin/Wubi → "zh", ABC/US → "en", Kotoeri → "ja"
    private func resolveTranscriptionLanguage() -> String {
        let stored = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
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
}
