import SwiftUI
import ServiceManagement
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
    @Published var customModifiers: NSEvent.ModifierFlags = .control

    let coordinator: AppCoordinator
    let modelManager: ModelManager
    private var accessibilityPollTask: Task<Void, Never>?
    private var testWatchTask: Task<Void, Never>?

    init(coordinator: AppCoordinator, modelManager: ModelManager) {
        self.coordinator = coordinator
        self.modelManager = modelManager

        let status = coordinator.permissions.checkAll()
        micGranted = status.microphone == .granted
        accessibilityGranted = status.accessibility == .granted
    }

    func nextStep() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }

        switch next {
        case .microphone where micGranted:
            step = .microphone
            nextStep()
        case .accessibility where accessibilityGranted:
            step = .accessibility
            nextStep()
        case .modelDownload where modelManager.state == .ready:
            step = .modelDownload
            nextStep()
        default:
            step = next
        }
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

    func checkHotkeyConflict() {
        // Only check if still using default Ctrl+Space
        let savedKey = UserDefaults.standard.object(forKey: "hotkeyKeyCode")
        if savedKey == nil {
            hotkeyConflictDetected = HotkeyConflictDetector.ctrlSpaceConflictsWithInputSources()
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        try? SMAppService.mainApp.register()
        accessibilityPollTask?.cancel()
        testWatchTask?.cancel()
    }

    deinit {
        accessibilityPollTask?.cancel()
        testWatchTask?.cancel()
    }
}
