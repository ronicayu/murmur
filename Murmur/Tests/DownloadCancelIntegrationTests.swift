import XCTest
import Darwin
@testable import Murmur

// MARK: - FU-03: Subprocess-lifecycle integration test suite
//
// These tests exercise the three behaviors of ModelManager.cancelDownload() that
// unit tests cannot reach because `activeDownloadProcess` is nil in the unit test
// harness:
//
//   1. SIGTERM → poll → SIGKILL escalation (C6 fix, commit 7f0409f)
//   2. Partial-file cleanup after the subprocess is dead (C8 fix, commit fa53a81)
//   3. Cancel-then-redownload race: cleanup Task must NOT delete new download's dir
//      when isDownloadActive is true when the Task fires (C8 race fix)
//
// Each test uses:
//   - A real subprocess (`/bin/sleep`, `/bin/sh`) as the stand-in for the downloader.
//   - `__testing_injectDownloadProcess` to inject the live Process into ModelManager.
//   - `__testing_setModelDirectory` to redirect all file operations to a temp dir.
//   - `__testing_setState` to put ModelManager into `.downloading` without a real download.
//
// Runtime: tests are intentionally slow (~2–3 s each) because they exercise real
// subprocess lifecycle including SIGKILL escalation. This is expected and accepted.
//
// Safety: every test writes only to a unique temp directory created in setUp and
// destroyed in tearDown. The real ~/Library/Application Support/Murmur path is
// never touched.

// MARK: - Stand-in subprocesses

/// A process that runs for 30 s unless it is signalled.
private func makeSleeper() -> Process {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
    proc.arguments = ["30"]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    return proc
}

/// Starts a shell that ignores SIGTERM, so only SIGKILL ends it, and returns
/// once the shell has said that the signal is ignored. Without that wait, a
/// SIGTERM sent right after launch ends the shell before its `trap` runs.
/// The shell's `sleep 1` children end by themselves within a second.
private func runSigtermIgnorer() throws -> Process {
    let proc = Process()
    let ready = Pipe()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", "trap '' TERM; echo ready; while :; do sleep 1 >/dev/null; done"]
    proc.standardOutput = ready
    proc.standardError = FileHandle.nullDevice
    try proc.run()
    let line = String(decoding: ready.fileHandleForReading.availableData, as: UTF8.self)
    guard line.hasPrefix("ready") else {
        proc.terminate()
        throw CocoaError(.fileReadUnknown)
    }
    return proc
}

// MARK: - Polling helpers

/// Poll `condition` every `intervalMs` milliseconds until it returns true or
/// `timeoutSeconds` elapses. Returns true if condition was satisfied.
@MainActor
private func pollUntil(
    timeoutSeconds: Double,
    intervalMs: Int = 100,
    condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(intervalMs))
    }
    return condition()
}

/// Poll until `kill(pid, 0)` returns -1 (i.e. the process is no longer alive).
private func pollUntilDead(pid: Int32, timeoutSeconds: Double) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if Darwin.kill(pid, 0) == -1 { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return Darwin.kill(pid, 0) == -1
}

// MARK: - Test class

@MainActor
final class DownloadCancelIntegrationTests: XCTestCase {

    private var manager: ModelManager!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Create a unique temp directory for this test run.
        // All model directory operations are redirected here via __testing_setModelDirectory.
        let base = FileManager.default.temporaryDirectory
        tempDir = base.appendingPathComponent(
            "MurmurIntegrationTest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Configure a fresh manager and redirect its model directory for .qwen3.
        manager = makeTestModelManager()

        // Redirect file ops to the temp dir.
        manager.__testing_setModelDirectory(tempDir, for: .qwen3)

        // Start in .downloading so cancelDownload() has something to cancel.
        manager.__testing_setState(.downloading(progress: 0.1, bytesPerSec: 0))
    }

    override func tearDownWithError() throws {
        // Always terminate any lingering subprocess and clean up disk.
        manager.__testing_setState(.notDownloaded)
        manager = nil

        if let dir = tempDir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil

        try super.tearDownWithError()
    }

    // MARK: - Test 1: Cancel + cleanup

    /// Verifies that after cancelDownload():
    ///   a. State resets to .notDownloaded synchronously (within 100ms).
    ///   b. The subprocess is dead within 3 seconds (kill(pid,0) == -1/ESRCH).
    ///   c. The model directory is removed within 3 seconds (cleanup Task ran).
    func test_cancelDownload_stateResets_processKilled_dirRemoved() async throws {
        // Arrange — spawn a long-lived subprocess.
        let proc = makeSleeper()
        try proc.run()
        let pid = proc.processIdentifier
        XCTAssertTrue(proc.isRunning, "Precondition: process must be running after proc.run()")

        // Plant a sentinel file so we can observe directory deletion.
        let sentinel = tempDir.appendingPathComponent("sentinel.txt")
        try "exists".write(to: sentinel, atomically: true, encoding: .utf8)

        // Inject the running process into ModelManager.
        manager.__testing_injectDownloadProcess(proc)

        // Act
        manager.cancelDownload()

        // Assert a: state must be .notDownloaded synchronously (checked inline,
        // no wait required — cancelDownload() is synchronous for state reset).
        XCTAssertEqual(
            manager.state, .notDownloaded,
            "State must reset to .notDownloaded synchronously after cancelDownload()"
        )
        XCTAssertFalse(
            manager.isDownloadActive,
            "isDownloadActive must be false immediately after cancelDownload()"
        )

        // Assert b: process must die within 3 seconds (normal SIGTERM path).
        let processDied = await pollUntilDead(pid: pid, timeoutSeconds: 3.0)
        XCTAssertTrue(
            processDied,
            "Process (pid: \(pid)) must be dead within 3 seconds after cancelDownload()"
        )

        // Assert c: model directory must be removed within 3 seconds.
        let dirGone = await pollUntil(timeoutSeconds: 3.0) {
            !FileManager.default.fileExists(atPath: self.tempDir.path)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempDir.path),
            "Model directory must be removed by cleanup Task within 3 seconds after cancel"
        )
        // Prevent tearDown from trying to double-remove an already-deleted dir.
        if dirGone { tempDir = nil }
    }

    // MARK: - Test 2: SIGKILL escalation

    /// Verifies that a SIGTERM-ignoring process is force-killed by the
    /// SIGKILL escalation.
    func test_cancelDownload_sigtermIgnored_processIsKilled() async throws {
        // Arrange — spawn a process that ignores SIGTERM.
        let proc = try runSigtermIgnorer()
        let pid = proc.processIdentifier
        XCTAssertTrue(proc.isRunning, "Precondition: SIGTERM-ignoring process must be running")

        manager.__testing_injectDownloadProcess(proc)

        // Act
        manager.cancelDownload()

        // Assert: state resets synchronously (before SIGKILL fires — state is a Swift
        // mutation on the main actor, independent of the background Task).
        XCTAssertEqual(
            manager.state, .notDownloaded,
            "State must reset synchronously even when the subprocess ignores SIGTERM"
        )

        // Assert: the process dies, and it dies by SIGKILL. The limit is far
        // above the 2-second escalation window so a slow machine does not
        // fail the test; what proves the escalation is the signal.
        let processDied = await pollUntilDead(pid: pid, timeoutSeconds: 15)
        XCTAssertTrue(
            processDied,
            "SIGTERM-ignoring process (pid: \(pid)) must be killed by the SIGKILL escalation"
        )
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationReason, .uncaughtSignal)
        XCTAssertEqual(proc.terminationStatus, SIGKILL)

        // tempDir may have been deleted by cleanup Task — set to nil to prevent
        // tearDown double-remove (tearDown checks fileExists before removeItem).
    }

    // MARK: - Test 3: Cancel → immediate redownload race

    /// Verifies the C8 race fix: if a new download starts (isDownloadActive becomes
    /// true) within the ~2.1s cleanup window after cancelDownload(), the cleanup
    /// Task must NOT delete the model directory.
    func test_cancelDownload_redownloadStartsImmediately_dirNotDeleted() async throws {
        // Arrange — plant a sentinel file before cancel.
        let sentinel = tempDir.appendingPathComponent("sentinel.txt")
        try "exists".write(to: sentinel, atomically: true, encoding: .utf8)

        // Spawn a subprocess (doesn't need to do anything useful).
        let proc = makeSleeper()
        try proc.run()

        manager.__testing_injectDownloadProcess(proc)

        // Act: cancel, then IMMEDIATELY simulate a new download starting before
        // the ~2.1s cleanup window closes. The cleanup Task checks isDownloadActive
        // on the MainActor before calling removeItem — this __testing_setState call
        // sets isDownloadActive = true before that check runs.
        manager.cancelDownload()

        // State is now .notDownloaded (synchronously). Immediately flip back to
        // .downloading to simulate a user-triggered redownload starting within
        // the cleanup Task's wait window.
        manager.__testing_setState(.downloading(progress: 0.0, bytesPerSec: 0))
        XCTAssertTrue(
            manager.isDownloadActive,
            "Precondition: isDownloadActive must be true after simulating redownload start"
        )

        // Wait long enough for the cleanup Task to complete its entire poll + cleanup
        // cycle (2s poll + 100ms grace + some scheduling slack = 3s total).
        try await Task.sleep(for: .seconds(3))

        // Assert: sentinel file must still exist — cleanup was skipped because
        // isDownloadActive was true when the Task hopped to MainActor.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path),
            "Model directory must NOT be deleted when a new download is active — " +
            "C8 cleanup guard must have observed isDownloadActive == true and skipped removeItem"
        )

        // Also assert the simulated download state is still as we set it.
        XCTAssertTrue(
            manager.isDownloadActive,
            "isDownloadActive must still be true (new download still 'in progress')"
        )

        // Terminate the subprocess so tearDown is clean.
        proc.terminate()
    }
}
