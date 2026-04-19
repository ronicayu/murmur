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
//   - A real Python subprocess (`python3`) as the stand-in for `snapshot_download`.
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

// MARK: - Python availability helper

private func findPython3() -> URL? {
    let candidates = [
        "/usr/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        // miniforge / conda — picked up on developer machines
        "/Users/\(NSUserName())/miniforge3/bin/python3",
        "/Users/\(NSUserName())/opt/anaconda3/bin/python3",
    ]
    for path in candidates {
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
    }
    // Last resort: ask the shell (slow but reliable on PATH-configured machines)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["which", "python3"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { return nil }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path)
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
    private var python3: URL!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Locate python3 — skip the whole class if not available.
        guard let py = findPython3() else {
            throw XCTSkip(
                "python3 not found on this machine — skipping DownloadCancelIntegrationTests. " +
                "Install python3 via Xcode Command Line Tools, Homebrew, or the python.org installer."
            )
        }
        python3 = py

        // Create a unique temp directory for this test run.
        // All model directory operations are redirected here via __testing_setModelDirectory.
        let base = FileManager.default.temporaryDirectory
        tempDir = base.appendingPathComponent(
            "MurmurIntegrationTest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Configure a fresh manager and redirect its model directory for .onnx.
        UserDefaults.standard.set(ModelBackend.onnx.rawValue, forKey: "modelBackend")
        manager = ModelManager()
        _ = manager.setActiveBackend(.onnx)

        // Redirect file ops to the temp dir.
        manager.__testing_setModelDirectory(tempDir, for: .onnx)

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
        // Arrange — spawn a long-lived Python subprocess.
        let proc = Process()
        proc.executableURL = python3
        proc.arguments = ["-c", "import time; time.sleep(30)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
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

    /// Verifies that a SIGTERM-ignoring process is force-killed within 2.5 seconds,
    /// proving the 2-second SIGKILL escalation path fired.
    func test_cancelDownload_sigtermIgnored_sigkillFiredWithin2500ms() async throws {
        // Arrange — spawn a Python process that explicitly ignores SIGTERM.
        let proc = Process()
        proc.executableURL = python3
        proc.arguments = [
            "-c",
            "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
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

        // Assert: process must die within 2.5 seconds. The SIGKILL escalation fires
        // after the 2-second poll window, so the process should be dead shortly after
        // that. 2.5s gives a 500ms grace window on top of the escalation window.
        let processDied = await pollUntilDead(pid: pid, timeoutSeconds: 2.5)
        XCTAssertTrue(
            processDied,
            "SIGTERM-ignoring process (pid: \(pid)) must be killed within 2.5 seconds " +
            "— SIGKILL escalation must have fired after the 2-second wait window"
        )

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
        let proc = Process()
        proc.executableURL = python3
        proc.arguments = ["-c", "import time; time.sleep(30)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
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
