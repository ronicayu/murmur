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

        // Redirect both .onnx AND .whisper model directories to isolated temp
        // dirs via `__testing_setModelDirectory`. Several tests below read both
        // backends' paths; redirecting up-front prevents any accidental writes
        // to ~/Library/Application Support/Murmur/{Models-ONNX,Models-Whisper}/.
        defaults.set(ModelBackend.onnx.rawValue, forKey: backendKey)
        manager = ModelManager()

        let onnxTemp = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("b3b4-onnx-\(UUID().uuidString)")
        let whisperTemp = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("b3b4-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: onnxTemp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: whisperTemp, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(onnxTemp, for: .onnx)
        manager.__testing_setModelDirectory(whisperTemp, for: .whisper)

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

        // FU-04: write a manifest so manifestIsValid(for:) returns true.
        // Without this, modelPath(for:) returns nil even with files on disk.
        let manifest = try manager.buildManifest(for: .onnx)
        try manager.writeManifest(manifest, for: .onnx)

        tempModelRoot = dir
        whisperTempRoot = whisperTemp
    }

    private var whisperTempRoot: URL!

    override func tearDownWithError() throws {
        if let root = tempModelRoot, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        if let wRoot = whisperTempRoot, FileManager.default.fileExists(atPath: wRoot.path) {
            try? FileManager.default.removeItem(at: wRoot)
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

        // FU-04: write a manifest so manifestIsValid(for:) returns true.
        let manifest = try manager.buildManifest(for: .whisper)
        try manager.writeManifest(manifest, for: .whisper)

        // Act + Assert — .whisper is NOT active; result is manifest validity
        XCTAssertTrue(manager.isModelDownloaded(for: .whisper),
                      "Non-active backend with files and manifest present must return true")
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
    private var onnxTempRoot: URL!
    private let defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults.set(ModelBackend.onnx.rawValue, forKey: "modelBackend")
        manager = ModelManager()
        // Redirect all ONNX model I/O into an isolated temp dir — the tests
        // below plant files via manager.modelDirectory(for: .onnx) which,
        // without this redirect, resolves to the live Application Support path.
        onnxTempRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("activebackend-onnx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: onnxTempRoot, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(onnxTempRoot, for: .onnx)
        _ = manager.setActiveBackend(.onnx)
    }

    override func tearDownWithError() throws {
        if let root = onnxTempRoot, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
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
        // FU-04: write a manifest so refreshState() resolves to .ready.
        let manifest = try manager.buildManifest(for: .onnx)
        try manager.writeManifest(manifest, for: .onnx)

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
    private var onnxTempRoot: URL!
    private var whisperTempRoot: URL!
    private var cancellables = Set<AnyCancellable>()

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.set(ModelBackend.onnx.rawValue, forKey: "modelBackend")
        manager = ModelManager()
        // Defensive redirect: these tests call setActiveBackend/cancelDownload
        // which in some paths touch the model directory. Point all backends at
        // temp dirs so nothing can reach the real Application Support.
        onnxTempRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("setactive-onnx-\(UUID().uuidString)")
        whisperTempRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("setactive-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: onnxTempRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: whisperTempRoot, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(onnxTempRoot, for: .onnx)
        manager.__testing_setModelDirectory(whisperTempRoot, for: .whisper)
        // Ensure we start from a known backend
        _ = manager.setActiveBackend(.onnx)
    }

    override func tearDownWithError() throws {
        // Leave state clean — force back to notDownloaded so subsequent tests
        // that check isDownloadActive start fresh.
        manager.__testing_setState(.notDownloaded)
        _ = manager.setActiveBackend(.onnx)
        manager = nil
        if let root = onnxTempRoot { try? FileManager.default.removeItem(at: root) }
        if let wRoot = whisperTempRoot { try? FileManager.default.removeItem(at: wRoot) }
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

    // MARK: C5 — same-value short-circuit (regression test)
    //
    // setActiveBackend(currentBackend) must return true (trivially accepted) but
    // must NOT fire committedBackendChange. Any emission would cause MurmurApp
    // to tear down and rebuild the live transcription service unnecessarily —
    // the exact regression C5 describes.

    func test_setActiveBackend_sameValue_returnsTrue() {
        // Arrange — backend is .onnx (set in setUp)
        manager.__testing_setState(.notDownloaded)
        XCTAssertEqual(manager.activeBackend, .onnx)

        // Act — call with the current backend
        let accepted = manager.setActiveBackend(.onnx)

        // Assert — should be "accepted" (nothing to do)
        XCTAssertTrue(accepted,
            "setActiveBackend with same backend must return true (desired state already in effect)")
    }

    func test_setActiveBackend_sameValue_doesNotFireCommittedBackendChange() {
        // Arrange
        manager.__testing_setState(.notDownloaded)
        XCTAssertEqual(manager.activeBackend, .onnx)

        var emissionCount = 0
        manager.committedBackendChange
            .sink { _ in emissionCount += 1 }
            .store(in: &cancellables)

        // Act — call twice with the current backend
        _ = manager.setActiveBackend(.onnx)
        _ = manager.setActiveBackend(.onnx)

        // Assert — committedBackendChange must never fire for same-value calls
        XCTAssertEqual(emissionCount, 0,
            "committedBackendChange must not emit when backend is unchanged — " +
            "any emission would trigger MurmurApp to rebuild the transcription service")
    }

    func test_setActiveBackend_sameValue_doesNotRewriteUserDefaults() {
        // Arrange — record the write count by observing UserDefaults KVO
        manager.__testing_setState(.notDownloaded)
        let key = "modelBackend"
        let before = UserDefaults.standard.string(forKey: key)
        XCTAssertEqual(before, ModelBackend.onnx.rawValue)

        // We can't count writes directly, but we verify the value is unchanged
        // and that no observable side effects fired (see sibling test above).
        // This test documents the contract: same-value call must not persist anything new.
        _ = manager.setActiveBackend(.onnx)

        let after = UserDefaults.standard.string(forKey: key)
        XCTAssertEqual(after, ModelBackend.onnx.rawValue,
            "UserDefaults value must remain the same after a same-value setActiveBackend call")
        XCTAssertEqual(manager.activeBackend, .onnx,
            "activeBackend must remain unchanged after same-value call")
    }
}

// MARK: - C8: cleanup Task skips removeItem when a new download is in progress
//
// These tests verify the C8 race-condition fix: when the background cleanup Task
// runs after cancelDownload() but finds that a new download has started for the
// same backend, it must NOT delete the model directory (which the new download
// is actively writing into).
//
// The test seam `__testing_runCleanupAfterCancel(for:)` directly invokes the
// cleanup logic so we can drive it without a real subprocess.
//
// SAFETY NOTE: Both tests write a sentinel file into and then potentially delete
// manager.modelDirectory(for: .onnx) — the same path that holds a real user
// ONNX model when one is installed. setUp therefore skips the entire class when
// real model files are already present (modelPath(for: .onnx) != nil), preventing
// any destructive operation on a developer's pre-downloaded model.
// Approach (b) from the QA fix request (073/072): XCTSkipIf in setUp.

@MainActor
final class CancelDownloadCleanupRaceTests: XCTestCase {

    private var manager: ModelManager!
    private var tempModelDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.set(ModelBackend.onnx.rawValue, forKey: "modelBackend")
        manager = ModelManager()

        // Redirect the ONNX model directory to an isolated temp dir BEFORE
        // planting the sentinel. This replaces the earlier XCTSkipIf-on-real-
        // model guard so the tests run on every machine and cannot touch a
        // user's pre-downloaded model under ~/Library/Application Support.
        let redirect = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("cancelrace-onnx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: redirect, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(redirect, for: .onnx)

        // Plant a sentinel file in the (now-redirected) ONNX model directory so
        // we can verify whether removeItem was called by the cleanup logic.
        let fm = FileManager.default
        tempModelDir = manager.modelDirectory(for: .onnx)
        try fm.createDirectory(at: tempModelDir, withIntermediateDirectories: true)
        let sentinel = tempModelDir.appendingPathComponent("sentinel.txt")
        try "exists".write(to: sentinel, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        // Clean up the sentinel directory we may have created.
        // tempModelDir is nil when setUp skipped (XCTSkipIf throws before assignment).
        if let dir = tempModelDir {
            try? FileManager.default.removeItem(at: dir)
        }
        manager = nil
        try super.tearDownWithError()
    }

    func test_cleanupAfterCancel_skipsRemoveItem_whenNewDownloadIsActive() async {
        // Arrange — simulate a new download in progress for the same backend.
        manager.__testing_setState(.downloading(progress: 0.1, bytesPerSec: 50_000))
        XCTAssertTrue(manager.isDownloadActive, "Precondition: new download must be active")

        // Act — run the cleanup logic directly (bypasses subprocess lifecycle).
        await manager.__testing_runCleanupAfterCancel(for: .onnx)

        // Assert — the directory must still exist because cleanup was skipped.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempModelDir.path),
            "Cleanup must not remove the model directory when a new download is active"
        )
    }

    func test_cleanupAfterCancel_removesDirectory_whenNoDownloadIsActive() async {
        // Arrange — no download in progress.
        manager.__testing_setState(.notDownloaded)
        XCTAssertFalse(manager.isDownloadActive, "Precondition: no download must be active")

        // Act — run the cleanup logic directly.
        await manager.__testing_runCleanupAfterCancel(for: .onnx)

        // Assert — the directory must have been removed.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempModelDir.path),
            "Cleanup must remove the model directory when no download is active"
        )
    }
}

// MARK: - H4 + C6: cancelDownload terminates the active process
//
// These tests verify the synchronous state-reset guarantees of cancelDownload().
// The SIGKILL escalation path (C6 fix) is NOT exercised here because
// activeDownloadProcess is nil in the unit test harness — no real Process is
// running. The SIGKILL path requires a real subprocess and is tracked as a
// QA integration test in handoff 068_QA_EN_b3-b4-integration-ask.md.
//
// What IS tested:
//   - State resets to .notDownloaded synchronously (UI unlocks immediately).
//   - isDownloadActive becomes false synchronously.
//   - A backend switch is accepted right after cancel.
//   - statusMessage is cleared synchronously.

@MainActor
final class CancelDownloadTests: XCTestCase {

    private var manager: ModelManager!
    private var onnxTempRoot: URL!
    private var whisperTempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.set(ModelBackend.onnx.rawValue, forKey: "modelBackend")
        manager = ModelManager()
        // Defensive redirect for both backends referenced by these tests —
        // cancelDownload's detached cleanup task could remove the model dir
        // if a subprocess were ever injected.
        onnxTempRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("canceldl-onnx-\(UUID().uuidString)")
        whisperTempRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("canceldl-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: onnxTempRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: whisperTempRoot, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(onnxTempRoot, for: .onnx)
        manager.__testing_setModelDirectory(whisperTempRoot, for: .whisper)
    }

    override func tearDownWithError() throws {
        if let root = onnxTempRoot { try? FileManager.default.removeItem(at: root) }
        if let wRoot = whisperTempRoot { try? FileManager.default.removeItem(at: wRoot) }
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

    func test_cancelDownload_clearsStatusMessage() {
        // Arrange
        manager.__testing_setState(.downloading(progress: 0.5, bytesPerSec: 100_000))

        // Act
        manager.cancelDownload()

        // Assert — statusMessage must be cleared synchronously so no stale
        // "Downloading..." text lingers in UI after cancel.
        XCTAssertEqual(manager.statusMessage, "",
            "cancelDownload must clear statusMessage synchronously")
    }
}
