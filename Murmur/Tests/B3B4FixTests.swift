import XCTest
import Combine
@testable import Murmur

// MARK: - B4: isModelDownloaded(for:) state-machine gating
//
// Tests for the fix in ModelManager.isModelDownloaded(for:) that makes the active
// backend's result authoritative via the state machine.
//
// COVERAGE NOTE: States .downloading, .verifying, .corrupt, and .error are
// private(set) and can only be reached via real async flows (download(), verify()).
// Tests for those states require a test seam in ModelManager. See handoff
// 062_QA_EN_b4-state-seam-request.md for the EN ask.

@MainActor
final class IsModelDownloadedActiveBackendTests: XCTestCase {

    // A temp directory planted with all required ONNX files, giving us a real
    // .ready state without running an actual download.
    private var tempModelRoot: URL!
    private var manager: ModelManager!
    private let defaults = UserDefaults.standard
    private let backendKey = "modelBackend"

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Isolate from real application support by pointing the active backend's
        // directory at a temp root we control.
        // Strategy: plant files under the real appSupport path that ModelManager
        // resolves, then clean them up in tearDown.
        // (ModelManager.modelDirectory is derived from activeBackend.modelSubdirectory
        //  and cannot be injected without a test seam — we use the real path.)

        // Force active backend to .onnx to have a known required-files set.
        defaults.set(ModelBackend.onnx.rawValue, forKey: backendKey)
        manager = ModelManager()
        _ = manager.setActiveBackend(.onnx)

        let dir = manager.modelDirectory(for: .onnx)
        let onnxDir = dir.appendingPathComponent("onnx")
        try FileManager.default.createDirectory(at: onnxDir, withIntermediateDirectories: true)

        // Plant the three required files for .onnx
        for file in ModelBackend.onnx.requiredFiles {
            let url = dir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("stub".utf8).write(to: url)
        }

        tempModelRoot = dir
    }

    override func tearDownWithError() throws {
        if let root = tempModelRoot, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        manager = nil
        try super.tearDownWithError()
    }

    // MARK: .ready + files present → true

    func test_activeBackend_readyState_filesPresent_returnsTrue() {
        // Arrange — refreshState() will detect the planted files and set .ready
        manager.refreshState()

        // Assert
        XCTAssertEqual(manager.state, .ready,
                       "Precondition: state must be .ready after planting required files")
        XCTAssertTrue(manager.isModelDownloaded(for: .onnx),
                      "Active backend in .ready state with files present must return true")
    }

    // MARK: .notDownloaded + files absent → false (initial state, no files)

    func test_activeBackend_notDownloadedState_filesAbsent_returnsFalse() {
        // Arrange — use a fresh manager pointing at .whisper (no files exist for it)
        _ = manager.setActiveBackend(.whisper)
        // refreshState() is called by setActiveBackend; .whisper has no planted files so
        // state will be .notDownloaded
        XCTAssertEqual(manager.state, .notDownloaded,
                       "Precondition: state must be .notDownloaded when no files exist")

        // Assert
        XCTAssertFalse(manager.isModelDownloaded(for: .whisper),
                       "Active backend in .notDownloaded state must return false")

        // Clean up .whisper switch
        _ = manager.setActiveBackend(.onnx)
    }

    // MARK: .ready + files absent → false (defensive: state says ready but disk disagrees)
    //
    // This tests the combined check `state == .ready && modelPath != nil`.
    // The only in-test way to have .ready with no files is to delete the files after
    // refreshState() sets .ready, then query isModelDownloaded without re-running
    // refreshState(). refreshState() is what keeps state honest; the combined check
    // in isModelDownloaded is a belt-and-suspenders guard.

    func test_activeBackend_readyState_filesDeleted_returnsFalse() throws {
        // Arrange — plant files so state becomes .ready
        manager.refreshState()
        XCTAssertEqual(manager.state, .ready, "Precondition: state must be .ready")

        // Delete files while state stays .ready (simulates race / external deletion)
        try FileManager.default.removeItem(at: tempModelRoot)
        tempModelRoot = nil   // prevent double-remove in tearDown

        // Do NOT call refreshState() — state still claims .ready but files are gone
        // Act + Assert
        XCTAssertFalse(manager.isModelDownloaded(for: .onnx),
                       "Active backend: .ready state with missing files must still return false")
    }

    // MARK: Non-active backend: file-existence is the only signal

    func test_nonActiveBackend_filesPresent_returnsTrue() throws {
        // Arrange — ensure active is .onnx, plant files for .whisper
        _ = manager.setActiveBackend(.onnx)
        let whisperDir = manager.modelDirectory(for: .whisper)
        let onnxSubdir = whisperDir.appendingPathComponent("onnx")
        try FileManager.default.createDirectory(at: onnxSubdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: whisperDir) }

        for file in ModelBackend.whisper.requiredFiles {
            let url = whisperDir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("stub".utf8).write(to: url)
        }

        // Act + Assert — .whisper is NOT active; result is file-existence only
        XCTAssertTrue(manager.isModelDownloaded(for: .whisper),
                      "Non-active backend with files present must return true")
    }

    func test_nonActiveBackend_filesAbsent_returnsFalse() {
        // Arrange — ensure active is .onnx.
        // Use .whisper as the probe: plant no files for it, then verify.
        // We guard against an environment where whisper files already exist.
        _ = manager.setActiveBackend(.onnx)
        let whisperDir = manager.modelDirectory(for: .whisper)
        let whisperFilesExist = ModelBackend.whisper.requiredFiles.allSatisfy { file in
            FileManager.default.fileExists(atPath: whisperDir.appendingPathComponent(file).path)
        }
        guard !whisperFilesExist else {
            // Skip: this machine has whisper model files downloaded — can't test "absent" case.
            // The inverse (filesPresent → true) is already covered by test_nonActiveBackend_filesPresent_returnsTrue.
            return
        }

        // Act + Assert
        XCTAssertFalse(manager.isModelDownloaded(for: .whisper),
                       "Non-active backend with no files must return false")
    }

    // MARK: Only .ready makes active backend return true — other state values return false

    func test_activeBackend_notDownloadedState_returnsAlwaysFalse() {
        // Arrange — delete files so state reverts to .notDownloaded
        if let root = tempModelRoot {
            try? FileManager.default.removeItem(at: root)
            tempModelRoot = nil
        }
        manager.refreshState()
        XCTAssertEqual(manager.state, .notDownloaded)

        XCTAssertFalse(manager.isModelDownloaded(for: .onnx))
    }
}

// MARK: - C1: activeBackend.didSet revert during active download
//
// Tests the guard added to activeBackend.didSet that refuses a backend switch
// while isDownloadActive == true.
//
// COVERAGE NOTE: isDownloadActive is true only when state == .downloading or
// .verifying, both of which are private(set) and require a real download flow.
// The mid-flight revert test (attempt switch while .downloading returns false)
// requires a test seam.  See handoff 062_QA_EN_b4-state-seam-request.md.

@MainActor
final class ActiveBackendDidSetGuardTests: XCTestCase {

    private var manager: ModelManager!
    private let defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults.set(ModelBackend.onnx.rawValue, forKey: "modelBackend")
        manager = ModelManager()
        _ = manager.setActiveBackend(.onnx)
    }

    override func tearDownWithError() throws {
        // Restore a known backend
        _ = manager.setActiveBackend(.onnx)
        manager = nil
        try super.tearDownWithError()
    }

    // MARK: Normal (non-downloading) state: switch is accepted

    func test_switchBackend_whenIdle_succeeds() {
        // Arrange
        XCTAssertFalse(manager.isDownloadActive,
                       "Precondition: no download in progress")
        XCTAssertEqual(manager.activeBackend, .onnx)

        // Act
        let accepted = manager.setActiveBackend(.whisper)

        // Assert
        XCTAssertTrue(accepted)
        XCTAssertEqual(manager.activeBackend, .whisper,
                       "Backend switch must succeed when no download is in progress")

        // Cleanup
        _ = manager.setActiveBackend(.onnx)
    }

    func test_switchBackend_whenIdle_persistsToUserDefaults() {
        // Arrange
        XCTAssertFalse(manager.isDownloadActive)

        // Act
        _ = manager.setActiveBackend(.huggingface)

        // Assert
        XCTAssertEqual(defaults.string(forKey: "modelBackend"), ModelBackend.huggingface.rawValue,
                       "Successful switch must persist to UserDefaults")

        // Cleanup
        _ = manager.setActiveBackend(.onnx)
    }

    func test_switchBackend_sameValue_doesNotCorruptDefaults() {
        // Arrange
        XCTAssertEqual(manager.activeBackend, .onnx)

        // Act — same-value switch should still succeed cleanly
        let accepted = manager.setActiveBackend(.onnx)

        // Assert
        XCTAssertTrue(accepted)
        XCTAssertEqual(manager.activeBackend, .onnx)
        XCTAssertEqual(defaults.string(forKey: "modelBackend"), ModelBackend.onnx.rawValue)
    }

    // MARK: isDownloadActive reflects the right states

    func test_isDownloadActive_falseWhenNotDownloaded() {
        XCTAssertFalse(manager.isDownloadActive,
                       "isDownloadActive must be false in .notDownloaded state")
    }

    func test_isDownloadActive_falseWhenReady() throws {
        // Arrange — plant files so state becomes .ready
        let dir = manager.modelDirectory(for: .onnx)
        let onnxSub = dir.appendingPathComponent("onnx")
        try FileManager.default.createDirectory(at: onnxSub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for file in ModelBackend.onnx.requiredFiles {
            let url = dir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("stub".utf8).write(to: url)
        }
        manager.refreshState()
        XCTAssertEqual(manager.state, .ready)

        // Assert
        XCTAssertFalse(manager.isDownloadActive,
                       "isDownloadActive must be false in .ready state")
    }
}

// MARK: - B3: OnboardingViewModel re-publishes on ModelManager changes
//
// Tests that the Combine subscription wired in OnboardingViewModel.init correctly
// forwards ModelManager's objectWillChange into OnboardingViewModel.objectWillChange.

@MainActor
final class OnboardingViewModelRepublishTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: Forward propagation

    func test_modelManagerChange_firesOnboardingViewModelObjectWillChange() {
        // Arrange
        let coordinator = AppCoordinator()
        let modelManager = ModelManager()
        let viewModel = OnboardingViewModel(coordinator: coordinator, modelManager: modelManager)

        let expectation = XCTestExpectation(
            description: "OnboardingViewModel.objectWillChange fires when ModelManager changes"
        )
        expectation.expectedFulfillmentCount = 1

        viewModel.objectWillChange
            .sink { expectation.fulfill() }
            .store(in: &cancellables)

        // Act — switching activeBackend changes a @Published property on ModelManager,
        // which fires ModelManager.objectWillChange, which the subscription in
        // OnboardingViewModel.init must forward.
        let newBackend: ModelBackend = modelManager.activeBackend == .onnx ? .whisper : .onnx
        _ = modelManager.setActiveBackend(newBackend)

        // Assert — restore backend to avoid polluting other tests
        defer { _ = modelManager.setActiveBackend(.onnx) }

        wait(for: [expectation], timeout: 1.0)
    }

    func test_multipleModelManagerChanges_eachFiresForwardedNotification() {
        // Arrange
        let coordinator = AppCoordinator()
        let modelManager = ModelManager()
        let viewModel = OnboardingViewModel(coordinator: coordinator, modelManager: modelManager)

        let expectation = XCTestExpectation(
            description: "Each ModelManager change fires OnboardingViewModel.objectWillChange"
        )
        expectation.expectedFulfillmentCount = 2

        viewModel.objectWillChange
            .sink { expectation.fulfill() }
            .store(in: &cancellables)

        // Act — two distinct backend switches
        _ = modelManager.setActiveBackend(.whisper)
        _ = modelManager.setActiveBackend(.onnx)

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: No leak: subscription released when viewModel is deallocated

    func test_subscriptionReleased_whenViewModelDeallocated_noZombieSink() {
        // Arrange
        let coordinator = AppCoordinator()
        let modelManager = ModelManager()
        var viewModel: OnboardingViewModel? = OnboardingViewModel(
            coordinator: coordinator,
            modelManager: modelManager
        )

        var fireCount = 0
        // Subscribe to modelManager directly — if viewModel's internal sink were a
        // zombie (strong capture of dead self), it would crash or retain viewModel.
        let directExpectation = XCTestExpectation(
            description: "modelManager.objectWillChange still fires after viewModel is gone"
        )
        modelManager.objectWillChange
            .sink {
                fireCount += 1
                if fireCount == 1 { directExpectation.fulfill() }
            }
            .store(in: &cancellables)

        // Act — deallocate the view model
        viewModel = nil

        // Trigger a ModelManager change after dealloc — must not crash (no zombie sink)
        _ = modelManager.setActiveBackend(.whisper)
        defer { _ = modelManager.setActiveBackend(.onnx) }

        // modelManager itself still fires — verify it's healthy
        wait(for: [directExpectation], timeout: 1.0)
        XCTAssertGreaterThanOrEqual(fireCount, 1,
            "ModelManager must still publish changes after OnboardingViewModel is gone")
        // The test passing without EXC_BAD_ACCESS is the key assertion: no zombie sink.
        _ = viewModel // suppress unused warning
    }
}

// MARK: - C3 + C4: setActiveBackend guard with test seam
//
// Uses the DEBUG-only __testing_setState seam to drive ModelManager into
// .downloading and .verifying without a real subprocess.
//
// These tests cover:
//   C3 — committedBackendChange does NOT fire when a switch is refused, so
//        MurmurApp.onReceive never replaces the transcription service mid-download.
//   C4 — The guard is actually exercised; previously there was zero direct test
//        coverage of the "switch refused while downloading" branch.

@MainActor
final class SetActiveBackendGuardTests: XCTestCase {

    private var manager: ModelManager!
    private var cancellables = Set<AnyCancellable>()

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.set(ModelBackend.onnx.rawValue, forKey: "modelBackend")
        manager = ModelManager()
        // Ensure we start from a known backend
        _ = manager.setActiveBackend(.onnx)
    }

    override func tearDownWithError() throws {
        // Leave state clean — force back to notDownloaded so subsequent tests
        // that check isDownloadActive start fresh.
        manager.__testing_setState(.notDownloaded)
        _ = manager.setActiveBackend(.onnx)
        manager = nil
        cancellables.removeAll()
        try super.tearDownWithError()
    }

    // MARK: Refused while .downloading

    func test_setActiveBackend_whileDownloading_returnsFalse() {
        // Arrange
        manager.__testing_setState(.downloading(progress: 0.5, bytesPerSec: 100_000))
        XCTAssertTrue(manager.isDownloadActive, "Precondition: isDownloadActive must be true")
        XCTAssertEqual(manager.activeBackend, .onnx)

        // Act
        let accepted = manager.setActiveBackend(.whisper)

        // Assert
        XCTAssertFalse(accepted, "setActiveBackend must refuse while state == .downloading")
        XCTAssertEqual(manager.activeBackend, .onnx,
                       "activeBackend must remain unchanged after refused switch")
    }

    func test_setActiveBackend_whileDownloading_activeBackendUnchanged() {
        // Arrange
        manager.__testing_setState(.downloading(progress: -1, bytesPerSec: 0))

        // Act
        _ = manager.setActiveBackend(.huggingface)

        // Assert — backend reverted
        XCTAssertEqual(manager.activeBackend, .onnx)
    }

    // MARK: Refused while .verifying

    func test_setActiveBackend_whileVerifying_returnsFalse() {
        // Arrange
        manager.__testing_setState(.verifying)
        XCTAssertTrue(manager.isDownloadActive, "Precondition: isDownloadActive must be true")

        // Act
        let accepted = manager.setActiveBackend(.whisper)

        // Assert
        XCTAssertFalse(accepted, "setActiveBackend must refuse while state == .verifying")
        XCTAssertEqual(manager.activeBackend, .onnx,
                       "activeBackend must remain unchanged after refused switch (verifying)")
    }

    // MARK: committedBackendChange does NOT fire when refused (C3)

    func test_committedBackendChange_doesNotFireWhenSwitchRefused_downloading() {
        // Arrange
        manager.__testing_setState(.downloading(progress: 0.5, bytesPerSec: 50_000))

        var committedFired = false
        manager.committedBackendChange
            .sink { _ in committedFired = true }
            .store(in: &cancellables)

        // Act — attempt refused switch
        _ = manager.setActiveBackend(.whisper)

        // Assert — the committed publisher must NOT have fired
        XCTAssertFalse(committedFired,
            "committedBackendChange must not emit when switch is refused during download")
    }

    func test_committedBackendChange_doesNotFireWhenSwitchRefused_verifying() {
        // Arrange
        manager.__testing_setState(.verifying)

        var committedFired = false
        manager.committedBackendChange
            .sink { _ in committedFired = true }
            .store(in: &cancellables)

        // Act
        _ = manager.setActiveBackend(.whisper)

        // Assert
        XCTAssertFalse(committedFired,
            "committedBackendChange must not emit when switch is refused during verification")
    }

    // MARK: committedBackendChange DOES fire when switch is accepted

    func test_committedBackendChange_firesWhenSwitchAccepted() {
        // Arrange — not downloading
        manager.__testing_setState(.notDownloaded)
        XCTAssertFalse(manager.isDownloadActive)

        var receivedBackend: ModelBackend?
        manager.committedBackendChange
            .sink { receivedBackend = $0 }
            .store(in: &cancellables)

        // Act
        let accepted = manager.setActiveBackend(.whisper)

        // Assert
        XCTAssertTrue(accepted)
        XCTAssertEqual(receivedBackend, .whisper,
            "committedBackendChange must emit the new backend when switch is accepted")
    }

    // MARK: Switch accepted after cancel (state returns to .notDownloaded)

    func test_setActiveBackend_afterCancel_isAccepted() {
        // Arrange — simulate a cancelled download (state reset to .notDownloaded)
        manager.__testing_setState(.downloading(progress: 0.5, bytesPerSec: 0))
        XCTAssertTrue(manager.isDownloadActive)

        // Simulate cancel resetting state
        manager.__testing_setState(.notDownloaded)
        XCTAssertFalse(manager.isDownloadActive, "After cancel, isDownloadActive must be false")

        // Act
        let accepted = manager.setActiveBackend(.whisper)

        // Assert
        XCTAssertTrue(accepted, "setActiveBackend must succeed after download is cancelled")
        XCTAssertEqual(manager.activeBackend, .whisper)
    }
}

// MARK: - H4: cancelDownload terminates the active process

@MainActor
final class CancelDownloadTests: XCTestCase {

    private var manager: ModelManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.set(ModelBackend.onnx.rawValue, forKey: "modelBackend")
        manager = ModelManager()
    }

    override func tearDownWithError() throws {
        manager = nil
        try super.tearDownWithError()
    }

    func test_cancelDownload_setsStateToNotDownloaded() {
        // Arrange — simulate an in-flight download
        manager.__testing_setState(.downloading(progress: 0.5, bytesPerSec: 100_000))
        XCTAssertTrue(manager.isDownloadActive)

        // Act
        manager.cancelDownload()

        // Assert
        XCTAssertEqual(manager.state, .notDownloaded,
            "cancelDownload must synchronously set state to .notDownloaded")
    }

    func test_cancelDownload_setsIsDownloadActiveToFalse() {
        // Arrange
        manager.__testing_setState(.verifying)
        XCTAssertTrue(manager.isDownloadActive)

        // Act
        manager.cancelDownload()

        // Assert — isDownloadActive derived from state, so this confirms the state reset
        XCTAssertFalse(manager.isDownloadActive,
            "isDownloadActive must be false immediately after cancelDownload()")
    }

    func test_cancelDownload_allowsSubsequentBackendSwitch() {
        // Arrange — simulate a cancelled download: isDownloadActive was true, now false
        manager.__testing_setState(.downloading(progress: 0.3, bytesPerSec: 0))
        manager.cancelDownload()
        XCTAssertFalse(manager.isDownloadActive, "Precondition: download must be cancelled")

        // Act — backend switch should now be accepted
        let accepted = manager.setActiveBackend(.whisper)

        // Assert
        XCTAssertTrue(accepted,
            "Backend switch must be accepted immediately after cancelDownload()")
        XCTAssertEqual(manager.activeBackend, .whisper)
    }
}
