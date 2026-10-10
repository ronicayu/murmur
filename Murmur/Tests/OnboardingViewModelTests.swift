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
        coordinator = AppCoordinator(
            transcription: SpyTranscriptionService(),
            pill: SpyPillController()
        )
        savedHotkey = .rightCommand
        appliedHotkeys = []
        viewModel = OnboardingViewModel(
            coordinator: coordinator,
            modelManager: ModelManager(),
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
