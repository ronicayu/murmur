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
    /// The user chose to transcribe recordings only, for now: no
    /// Accessibility prompt, no hotkey practice.
    @Published private(set) var dictationSkipped = false
    @Published var customKey: Key = HotkeyPreference.defaultCustomKey
    @Published var customModifiers: NSEvent.ModifierFlags = HotkeyPreference.defaultCustomModifiers

    let coordinator: AppCoordinator
    let modelManager: ModelManager

    /// Steps actually shown to the user (mic merged into welcome; modelChoice skipped)
    static let visibleSteps: [OnboardingStep] = [
        .welcome, .modelDownload, .accessibility, .testTranscription, .done
    ]

    var visibleStepCount: Int { Self.visibleSteps.count }

    var visibleStepIndex: Int {
        Self.visibleSteps.firstIndex(of: step) ?? 0
    }
    private var accessibilityPollTask: Task<Void, Never>?
    private var testWatchTask: Task<Void, Never>?
    private var modelManagerCancellable: AnyCancellable?

    private let loadHotkey: () -> HotkeyTrigger
    private let applyHotkey: (HotkeyTrigger) -> Void

    /// - Parameters:
    ///   - loadHotkey: reads the saved shortcut.
    ///   - applyHotkey: puts a shortcut into effect and saves it. `nil`
    ///     registers it with the coordinator's hotkey service.
    ///   - startAt: `.accessibility` when the user sets up dictation after
    ///     onboarding, from the menu bar.
    init(
        coordinator: AppCoordinator,
        modelManager: ModelManager,
        startAt: OnboardingStep = .welcome,
        loadHotkey: @escaping () -> HotkeyTrigger = { HotkeyPreference.load() },
        applyHotkey: ((HotkeyTrigger) -> Void)? = nil
    ) {
        self.step = startAt
        self.coordinator = coordinator
        self.modelManager = modelManager
        self.loadHotkey = loadHotkey
        self.applyHotkey = applyHotkey ?? { [hotkey = coordinator.hotkey] trigger in
            hotkey.register(trigger: trigger)
            HotkeyPreference.save(trigger)
        }

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
            // One speech model — nothing to choose.
            step = .modelChoice
            nextStep()
        case .modelDownload where modelManager.state == .ready:
            step = .modelDownload
            nextStep()
        default:
            step = next
        }
    }


    /// Skips dictation's set-up and goes to the end. Nothing is asked for
    /// that only dictation needs.
    func skipDictation() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
        dictationSkipped = true
        step = .done
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

    func checkHotkeyConflict() {
        // Right Command is the default — it never conflicts with input source switching.
        // Only a saved Ctrl+Space shortcut can conflict.
        guard case .keyCombo(let key, let modifiers) = loadHotkey(),
              Self.isCtrlSpace(key: key, modifiers: modifiers) else { return }
        // Show the shortcut that is in effect, so that every other shortcut
        // the user records is a change.
        customKey = key
        customModifiers = modifiers
        hotkeyConflictDetected = HotkeyConflictDetector.ctrlSpaceConflictsWithInputSources()
    }

    /// Takes the replacement shortcut the user recorded: any change away from
    /// Ctrl+Space — key or modifiers — is put into effect, saved for the next
    /// launch, and clears the conflict.
    func customHotkeyDidChange() {
        guard !Self.isCtrlSpace(key: customKey, modifiers: customModifiers) else {
            hotkeyConflictDetected = HotkeyConflictDetector.ctrlSpaceConflictsWithInputSources()
            return
        }
        applyHotkey(.keyCombo(key: customKey, modifiers: customModifiers))
        hotkeyConflictDetected = false
    }

    static func isCtrlSpace(key: Key?, modifiers: NSEvent.ModifierFlags) -> Bool {
        key == .space && modifiers == .control
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        try? SMAppService.mainApp.register()
        teardown()
    }

    /// Undoes everything onboarding switched on. Called on every way out —
    /// finishing, or closing the window part-way — and safe to call twice.
    func teardown() {
        coordinator.skipAccessibilityCheck = false // Re-enable for normal use
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
        testWatchTask?.cancel()
        testWatchTask = nil
    }

    deinit {
        accessibilityPollTask?.cancel()
        testWatchTask?.cancel()
        // modelManagerCancellable is intentionally not nil'd here;
        // AnyCancellable cancels automatically on deallocation (ARC handles it).
    }
}
