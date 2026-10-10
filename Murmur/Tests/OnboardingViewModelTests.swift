import XCTest
@testable import Murmur

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    private var coordinator: AppCoordinator!
    private var viewModel: OnboardingViewModel!

    override func setUp() {
        super.setUp()
        coordinator = AppCoordinator(
            transcription: SpyTranscriptionService(),
            pill: SpyPillController()
        )
        viewModel = OnboardingViewModel(coordinator: coordinator, modelManager: ModelManager())
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
}
