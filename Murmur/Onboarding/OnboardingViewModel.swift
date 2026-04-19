import SwiftUI
import ServiceManagement
import Combine
import HotKey

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var step: OnboardingStep = .welcome
    @Published var micGranted = false
    @Published var accessibilityGranted = false
    @Published var testResult: String?
    @Published var testLanguage: DetectedLanguage?
    @Published var hotkeyPracticeMode = false
    @Published var hotkeyTestResult: String?
    @Published var hotkeyConflictDetected = false
    @Published var customKey: Key = .space
    @Published var customModifiers: NSEvent.ModifierFlags = .command // fallback if user switches off Right Command
    @Published var hfLoggedIn = false
    @Published var hfStatusMessage = ""

    let coordinator: AppCoordinator
    let modelManager: ModelManager

    /// Steps actually shown to the user (mic merged into welcome; modelChoice and huggingfaceLogin skipped)
    private static let visibleSteps: [OnboardingStep] = [
        .welcome, .accessibility, .modelDownload, .testTranscription, .done
    ]

    var visibleStepCount: Int { Self.visibleSteps.count }

    var visibleStepIndex: Int {
        Self.visibleSteps.firstIndex(of: step) ?? 0
    }
    private var accessibilityPollTask: Task<Void, Never>?
    private var testWatchTask: Task<Void, Never>?
    private var modelManagerCancellable: AnyCancellable?

    init(coordinator: AppCoordinator, modelManager: ModelManager) {
        self.coordinator = coordinator
        self.modelManager = modelManager

        let status = coordinator.permissions.checkAll()
        micGranted = status.microphone == .granted
        accessibilityGranted = status.accessibility == .granted

        // Forward ModelManager published-state changes into this view model so
        // SwiftUI re-renders OnboardingView when download progress/state changes.
        // (Nested ObservableObjects don't propagate automatically.)
        // ModelManager is @MainActor, so objectWillChange always fires on the main
        // thread. Do NOT add .receive(on: DispatchQueue.main) — that schedules the
        // sink on the *next* runloop tick, introducing a one-frame lag between
        // ModelManager state changes and OnboardingView re-renders (DA H6).
        modelManagerCancellable = modelManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    func nextStep() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }

        switch next {
        case .microphone:
            // Microphone is merged into welcome step — always skip
            step = .microphone
            nextStep()
        case .accessibility where accessibilityGranted:
            step = .accessibility
            nextStep()
        case .modelChoice:
            // Always use ONNX during onboarding — advanced backends are in Settings
            modelManager.setActiveBackend(.onnx)
            step = .modelChoice
            nextStep()
        case .huggingfaceLogin:
            // Skip — ONNX doesn't need HF login
            step = .huggingfaceLogin
            nextStep()
        case .modelDownload where modelManager.state == .ready:
            step = .modelDownload
            nextStep()
        default:
            step = next
        }
    }

    func selectBackend(_ backend: ModelBackend) {
        modelManager.setActiveBackend(backend)
    }

    func requestMicrophone() async {
        micGranted = await coordinator.permissions.requestMicrophone()
        if micGranted {
            nextStep()
        }
    }

    func openAccessibilitySettings() {
        coordinator.permissions.openAccessibilitySettings()
    }

    func startPollingAccessibility() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = Task {
            for await granted in coordinator.permissions.pollAccessibilityGranted() {
                accessibilityGranted = granted
                if granted {
                    nextStep()
                    break
                }
            }
        }
    }

    func downloadModel() async {
        do {
            try await modelManager.download()
        } catch {
            // Error state is handled by ModelManager's published state
        }
    }

    /// Toggle recording via the in-app button (step 5a).
    func toggleTestRecording() {
        if coordinator.state == .recording {
            coordinator.hotkey.emit(.stopRecording)
        } else if coordinator.state == .idle {
            coordinator.hotkey.emit(.startRecording)
        }
    }

    func enableTestMode() {
        // Skip accessibility check during onboarding — we show text in-app, not inject
        coordinator.skipAccessibilityCheck = true
    }

    func watchForTestResult() {
        testWatchTask?.cancel()
        testWatchTask = Task { [weak self] in
            guard let self else { return }
            var lastKnownResult: String?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                if let text = self.coordinator.lastTranscription, text != lastKnownResult {
                    if self.hotkeyPracticeMode {
                        self.hotkeyTestResult = text
                    } else {
                        self.testResult = text
                        self.testLanguage = self.coordinator.lastLanguage
                        // Auto-advance to hotkey practice after button test succeeds
                        self.hotkeyPracticeMode = true
                    }
                    lastKnownResult = text
                }
            }
        }
    }

    func loginHuggingFace() async {
        hfStatusMessage = "Opening browser for login..."

        // Find python
        let pythonPaths = [
            modelManager.pythonEnvPath.appendingPathComponent("bin/python3").path,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        guard let pythonPath = pythonPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            hfStatusMessage = "Error: Python3 not found. Install via: brew install python3"
            return
        }

        // Use huggingface-cli login which opens browser
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-m", "huggingface_hub.commands.huggingface_cli", "login"]

        // This needs a terminal for interactive login. Instead, open the token page
        // and have the user paste the token.
        NSWorkspace.shared.open(URL(string: "https://huggingface.co/settings/tokens")!)
        hfStatusMessage = "Create an access token, then paste it below."

        // For now, prompt via a dialog
        let alert = NSAlert()
        alert.messageText = "Paste your access token"
        alert.informativeText = "1. Copy a token from the page that just opened\n2. Paste it below\n\nThis lets Murmur download the speech model."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save Token")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "hf_..."
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let token = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                hfStatusMessage = "Error: No token entered"
                return
            }

            // Save token using huggingface_hub
            hfStatusMessage = "Saving token..."
            let saveScript = """
            from huggingface_hub import login
            login(token="\(token)")
            print("ok")
            """

            let saveProc = Process()
            saveProc.executableURL = URL(fileURLWithPath: pythonPath)
            saveProc.arguments = ["-c", saveScript]
            let stdout = Pipe()
            let stderr = Pipe()
            saveProc.standardOutput = stdout
            saveProc.standardError = stderr

            do {
                try saveProc.run()

                // Wait on a background thread to avoid blocking the main actor
                let exitStatus: Int32 = await withCheckedContinuation { continuation in
                    saveProc.terminationHandler = { proc in
                        continuation.resume(returning: proc.terminationStatus)
                    }
                }

                if exitStatus == 0 {
                    hfLoggedIn = true
                    hfStatusMessage = "Token saved successfully"
                } else {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    hfStatusMessage = "Error: \(String(errStr.suffix(150)))"
                }
            } catch {
                hfStatusMessage = "Error: \(error.localizedDescription)"
            }
        } else {
            hfStatusMessage = "Login cancelled"
        }
    }

    func checkHotkeyConflict() {
        // Right Command is the default — it never conflicts with input source switching.
        // Only check for conflict if user has set a custom Ctrl+Space hotkey.
        if let keyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int,
           let modsRaw = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt {
            let mods = NSEvent.ModifierFlags(rawValue: modsRaw)
            let isCtrlSpace = Key(carbonKeyCode: UInt32(keyCode)) == .space && mods == .control
            if isCtrlSpace {
                hotkeyConflictDetected = HotkeyConflictDetector.ctrlSpaceConflictsWithInputSources()
            }
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        coordinator.skipAccessibilityCheck = false // Re-enable for normal use
        try? SMAppService.mainApp.register()
        accessibilityPollTask?.cancel()
        testWatchTask?.cancel()
    }

    deinit {
        accessibilityPollTask?.cancel()
        testWatchTask?.cancel()
        // modelManagerCancellable is intentionally not nil'd here;
        // AnyCancellable cancels automatically on deallocation (ARC handles it).
    }
}
