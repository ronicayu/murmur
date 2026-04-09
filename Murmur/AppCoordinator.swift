import SwiftUI
import HotKey
import os

enum AppState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case injecting
    case undoable(text: String, method: InjectionMethod)
    case error(MurmurError)

    static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.recording, .recording),
             (.transcribing, .transcribing), (.injecting, .injecting):
            return true
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

    let hotkey: HotkeyService
    let audio: AudioService
    let transcription: TranscriptionService
    let injection: TextInjectionService
    let permissions: PermissionsService
    let audioFeedback: AudioFeedbackService
    let pill: FloatingPillController

    /// When true, skips accessibility check (for onboarding test where we show text in-app, not inject)
    var skipAccessibilityCheck = false
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

        // Unload model on sleep
        NotificationCenter.default.addObserver(
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
        transcription.killProcess()
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
            audio.cancelRecording()
            audioFeedback.playStopRecording()
            pill.hide()
            transition(to: .idle)
        }
    }

    private func startRecordingFlow() async {
        do {
            transition(to: .recording)
            audioFeedback.playStartRecording()
            pill.show(state: .recording, audioLevel: 0)

            // Monitor audio levels for the pill
            audioLevelTask?.cancel()
            audioLevelTask = Task { [weak self] in
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
            maxDurationTask = Task { [weak self] in
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

    private func stopAndTranscribe() async {
        audioLevelTask?.cancel()
        maxDurationTask?.cancel()
        audioFeedback.playStopRecording()

        do {
            transition(to: .transcribing)
            pill.show(state: .transcribing)

            let wav = try await withTimeout(seconds: 5, operation: "stop recording") {
                try await self.audio.stopRecording()
            }
            let result = try await withTimeout(seconds: 120, operation: "transcription") {
                let lang = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "en"
                return try await self.transcription.transcribe(audioURL: wav, language: lang)
            }

            transition(to: .injecting)
            pill.show(state: .injecting)

            let method = try await withTimeout(seconds: 5, operation: "text injection") {
                try await self.injection.inject(text: result.text)
            }

            lastTranscription = result.text
            lastLanguage = result.language
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
            undoTimer = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled {
                    self.removeUndoMonitor()
                    transition(to: .idle)
                }
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
                Task {
                    try? await Task.sleep(for: .seconds(2))
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
