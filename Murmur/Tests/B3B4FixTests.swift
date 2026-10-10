import XCTest
import Combine
@testable import Murmur

// MARK: - B4: isModelDownloaded(for:) state-machine gating
//
// Tests for the fix in ModelManager.isModelDownloaded(for:) that makes the active
// backend's result authoritative via the state machine.
//
// COVERAGE NOTE: States .downloading, .verifying, .corrupt, and .error are
// private(set) and can only be reached via the real async download() flow.
// Tests for those states require a test seam in ModelManager. See handoff
// 062_QA_EN_b4-state-seam-request.md for the EN ask.

@MainActor
final class IsModelDownloadedActiveBackendTests: XCTestCase {

    // A temp directory planted with all required model files, giving us a real
    // .ready state without running an actual download.
    private var tempModelRoot: URL!
    private var manager: ModelManager!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Redirect the model directory to an isolated temp dir via
        // `__testing_setModelDirectory`, so nothing here can touch the real
        // ~/Library/Application Support/Murmur/Models-Qwen3ASR/.
        manager = makeTestModelManager()

        let modelTemp = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("b3b4-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: modelTemp, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(modelTemp, for: .qwen3)

        let dir = manager.modelDirectory(for: .qwen3)

        // Plant the required files for .qwen3
        for file in ModelBackend.qwen3.requiredFiles {
            let url = dir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("stub".utf8).write(to: url)
        }

        // FU-04: write a manifest so manifestIsValid(for:) returns true.
        // Without this, modelPath(for:) returns nil even with files on disk.
        let manifest = try manager.buildManifest(for: .qwen3)
        try manager.writeManifest(manifest, for: .qwen3)
        manager.refreshState()

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
        XCTAssertTrue(manager.isModelDownloaded(for: .qwen3),
                      "Active backend in .ready state with files present must return true")
    }

    // MARK: .notDownloaded + files absent → false (initial state, no files)

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
        XCTAssertFalse(manager.isModelDownloaded(for: .qwen3),
                       "Active backend: .ready state with missing files must still return false")
    }

    // MARK: Non-active backend: file-existence is the only signal

    // MARK: Only .ready makes active backend return true — other state values return false

    func test_activeBackend_notDownloadedState_returnsAlwaysFalse() {
        // Arrange — delete files so state reverts to .notDownloaded
        if let root = tempModelRoot {
            try? FileManager.default.removeItem(at: root)
            tempModelRoot = nil
        }
        manager.refreshState()
        XCTAssertEqual(manager.state, .notDownloaded)

        XCTAssertFalse(manager.isModelDownloaded(for: .qwen3))
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
// manager.modelDirectory(for: .qwen3) — the same path that holds a real user
// ONNX model when one is installed. setUp therefore skips the entire class when
// real model files are already present (modelPath(for: .qwen3) != nil), preventing
// any destructive operation on a developer's pre-downloaded model.
// Approach (b) from the QA fix request (073/072): XCTSkipIf in setUp.

@MainActor
final class CancelDownloadCleanupRaceTests: XCTestCase {

    private var manager: ModelManager!
    private var tempModelDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        manager = makeTestModelManager()

        // Redirect the ONNX model directory to an isolated temp dir BEFORE
        // planting the sentinel. This replaces the earlier XCTSkipIf-on-real-
        // model guard so the tests run on every machine and cannot touch a
        // user's pre-downloaded model under ~/Library/Application Support.
        let redirect = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("cancelrace-onnx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: redirect, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(redirect, for: .qwen3)

        // Plant a sentinel file in the (now-redirected) ONNX model directory so
        // we can verify whether removeItem was called by the cleanup logic.
        let fm = FileManager.default
        tempModelDir = manager.modelDirectory(for: .qwen3)
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
        await manager.__testing_runCleanupAfterCancel(for: .qwen3)

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
        await manager.__testing_runCleanupAfterCancel(for: .qwen3)

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
//   - statusMessage is cleared synchronously.

@MainActor
final class CancelDownloadTests: XCTestCase {

    private var manager: ModelManager!
    private var modelTempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        manager = makeTestModelManager()
        // Defensive redirect — cancelDownload's detached cleanup task could
        // remove the model dir if a subprocess were ever injected.
        modelTempRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("canceldl-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: modelTempRoot, withIntermediateDirectories: true)
        manager.__testing_setModelDirectory(modelTempRoot, for: .qwen3)
    }

    override func tearDownWithError() throws {
        if let root = modelTempRoot { try? FileManager.default.removeItem(at: root) }
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
