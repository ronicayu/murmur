import XCTest
@testable import Murmur

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    private var coordinator: AppCoordinator!
    private var viewModel: OnboardingViewModel!
    private var savedHotkey: HotkeyTrigger = .rightCommand
    private var appliedHotkeys: [HotkeyTrigger] = []

    override func setUp() {
        super.setUp()
        coordinator = makeTestCoordinator(
            transcription: SpyTranscriptionService(),
            pill: SpyPillController()
        )
        savedHotkey = .rightCommand
        appliedHotkeys = []
        viewModel = OnboardingViewModel(
            coordinator: coordinator,
            modelManager: makeTestModelManager(),
            loadHotkey: { [unowned self] in self.savedHotkey },
            applyHotkey: { [unowned self] in self.appliedHotkeys.append($0) }
        )
    }

    override func tearDown() {
        viewModel.teardown()
        viewModel = nil
        coordinator = nil
        super.tearDown()
    }

    // MARK: - Dictation set-up can wait

    func test_afterWelcome_comesTheModel_notAccessibility() {
        XCTAssertEqual(viewModel.step, .welcome)
        viewModel.nextStep()
        XCTAssertEqual(viewModel.step, .modelDownload, "Precondition: no model in the test's directory")
    }

    func test_skipDictation_endsOnboarding_withoutAccessibility() {
        viewModel.step = .accessibility

        viewModel.skipDictation()

        XCTAssertEqual(viewModel.step, .done)
        XCTAssertTrue(viewModel.dictationSkipped)
    }

    func test_setUpDictationStart_dependsOnOnboardingAndTheModel() {
        XCTAssertEqual(OnboardingViewModel.setUpDictationStart(onboardingCompleted: false, modelReady: true), .welcome)
        XCTAssertEqual(OnboardingViewModel.setUpDictationStart(onboardingCompleted: true, modelReady: false), .modelDownload,
                       "Dictation cannot be tried without the model")
        XCTAssertEqual(OnboardingViewModel.setUpDictationStart(onboardingCompleted: true, modelReady: true), .accessibility)
    }

    func test_menuOffersSetUp_onlyWithoutAccessibility() {
        XCTAssertTrue(OnboardingViewModel.dictationNeedsSetUp(
            PermissionsStatus(microphone: .granted, accessibility: .denied)))
        XCTAssertFalse(OnboardingViewModel.dictationNeedsSetUp(
            PermissionsStatus(microphone: .granted, accessibility: .granted)))
    }

    func test_firstOnboarding_switchesOnLaunchAtLogin_butALaterSetUpDoesNot() {
        defer { UserDefaults.standard.removeObject(forKey: "onboardingCompleted") }
        var registered = 0
        for (start, expected) in [(OnboardingStep.welcome, 1), (.accessibility, 1), (.modelDownload, 1)] {
            let flow = OnboardingViewModel(
                coordinator: coordinator,
                modelManager: makeTestModelManager(),
                startAt: start,
                loadHotkey: { .rightCommand },
                applyHotkey: { _ in },
                registerLoginItem: { registered += 1 }
            )
            flow.completeOnboarding()
            XCTAssertEqual(registered, expected, "after a flow that began at \(start)")
        }
    }

    func test_accessibilityAlert_saysOnlyDictationNeedsIt() {
        let text = ErrorAlerts.permissionAlertText(for: .accessibility)
        XCTAssertTrue(text.message.contains("Transcribing recordings works without it"))
        XCTAssertEqual(text.button, "Set Up Dictation")
    }

    /// From the menu bar's "Set Up Dictation…".
    func test_setUpLater_startsAtTheAccessibilityStep() {
        let later = OnboardingViewModel(
            coordinator: coordinator,
            modelManager: makeTestModelManager(),
            startAt: .accessibility,
            loadHotkey: { .rightCommand },
            applyHotkey: { _ in }
        )
        defer { later.teardown() }
        XCTAssertEqual(later.step, .accessibility)
        XCTAssertFalse(later.dictationSkipped)
    }

    // MARK: - Leaving onboarding

    func test_teardown_restoresAccessibilityCheck_afterTestStep() {
        viewModel.enableTestMode()
        viewModel.watchForTestResult()
        XCTAssertTrue(coordinator.skipAccessibilityCheck)

        viewModel.teardown()

        XCTAssertFalse(coordinator.skipAccessibilityCheck)
    }

    func test_teardown_isSafeToCallTwice() {
        viewModel.enableTestMode()
        viewModel.teardown()
        viewModel.teardown()
        XCTAssertFalse(coordinator.skipAccessibilityCheck)
    }

    // MARK: - Hotkey conflict

    func test_isCtrlSpace_onlyForExactlyControlPlusSpace() {
        XCTAssertTrue(OnboardingViewModel.isCtrlSpace(key: .space, modifiers: .control))
        XCTAssertFalse(OnboardingViewModel.isCtrlSpace(key: .space, modifiers: .option))
        XCTAssertFalse(OnboardingViewModel.isCtrlSpace(key: .space, modifiers: [.control, .shift]))
        XCTAssertFalse(OnboardingViewModel.isCtrlSpace(key: .d, modifiers: .control))
        XCTAssertFalse(OnboardingViewModel.isCtrlSpace(key: nil, modifiers: .control))
    }

    func test_changingOnlyTheModifier_clearsConflict() {
        // Ctrl+Space -> Opt+Space: the key is the same, only the modifier moved.
        viewModel.customKey = .space
        viewModel.customModifiers = .control
        viewModel.hotkeyConflictDetected = true

        viewModel.customModifiers = .option
        viewModel.customHotkeyDidChange()

        XCTAssertFalse(viewModel.hotkeyConflictDetected)
    }

    func test_changingOnlyTheKey_clearsConflict() {
        viewModel.customKey = .space
        viewModel.customModifiers = .control
        viewModel.hotkeyConflictDetected = true

        viewModel.customKey = .d
        viewModel.customHotkeyDidChange()

        XCTAssertFalse(viewModel.hotkeyConflictDetected)
    }

    func test_replacementShortcut_isAppliedAndSaved() {
        viewModel.customKey = .space
        viewModel.customModifiers = .control
        viewModel.hotkeyConflictDetected = true

        viewModel.customKey = .d
        viewModel.customModifiers = .option
        viewModel.customHotkeyDidChange()

        XCTAssertEqual(appliedHotkeys, [.keyCombo(key: .d, modifiers: .option)])
    }

    func test_recordingCtrlSpaceAgain_appliesNothing() {
        viewModel.customKey = .space
        viewModel.customModifiers = .control

        viewModel.customHotkeyDidChange()

        XCTAssertTrue(appliedHotkeys.isEmpty)
    }

    func test_checkHotkeyConflict_showsTheSavedCtrlSpace() {
        // The recorder must show the shortcut in effect. If it showed some
        // other default, recording that default would not count as a change.
        savedHotkey = .keyCombo(key: .space, modifiers: .control)

        viewModel.checkHotkeyConflict()

        XCTAssertEqual(viewModel.customKey, .space)
        XCTAssertEqual(viewModel.customModifiers, .control)
    }

    func test_checkHotkeyConflict_rightCommand_isNoConflict() {
        savedHotkey = .rightCommand

        viewModel.checkHotkeyConflict()

        XCTAssertFalse(viewModel.hotkeyConflictDetected)
    }
}
