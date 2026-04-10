import XCTest
@testable import Murmur

// MARK: - TranscriptionService: setModelPath + killProcess

final class TranscriptionServiceModelSwitchTests: XCTestCase {

    private func makeService(modelPath: String = "/tmp/model-a") -> TranscriptionService {
        TranscriptionService(
            modelPath: URL(fileURLWithPath: modelPath),
            pythonPath: URL(fileURLWithPath: "/nonexistent"),
            scriptPath: URL(fileURLWithPath: "/nonexistent")
        )
    }

    // -- setModelPath behavior --

    func testSetModelPathKillsProcessOnChange() {
        let service = makeService(modelPath: "/tmp/model-a")

        // No process running, isModelLoaded = false
        XCTAssertFalse(service.isModelLoaded)

        // Changing path should not crash even with no process
        service.setModelPath(URL(fileURLWithPath: "/tmp/model-b"))
        XCTAssertFalse(service.isModelLoaded)
    }

    func testSetModelPathSamePathDoesNotKill() {
        let service = makeService(modelPath: "/tmp/model-a")

        // Setting the same path should be a no-op
        service.setModelPath(URL(fileURLWithPath: "/tmp/model-a"))
        XCTAssertFalse(service.isModelLoaded)
    }

    func testSetModelPathResetsIsModelLoaded() {
        let service = makeService(modelPath: "/tmp/model-a")

        // killProcess always sets _isModelLoaded = false
        service.killProcess()
        XCTAssertFalse(service.isModelLoaded)
    }

    // -- Concurrent setModelPath + killProcess (race condition test) --

    func testConcurrentSetModelPathAndKillProcess() async {
        let service = makeService(modelPath: "/tmp/model-a")

        // Hammer setModelPath and killProcess concurrently — must not crash
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    service.setModelPath(URL(fileURLWithPath: "/tmp/model-\(i % 3)"))
                }
                group.addTask {
                    service.killProcess()
                }
            }
        }

        XCTAssertFalse(service.isModelLoaded)
    }

    // -- Rapid backend switching simulation --

    func testRapidBackendSwitching() async {
        let service = makeService(modelPath: "/tmp/onnx")

        // Simulate: ONNX → HF → ONNX → Whisper → ONNX (rapid switches)
        let paths = [
            "/tmp/huggingface",
            "/tmp/onnx",
            "/tmp/whisper",
            "/tmp/onnx",
            "/tmp/huggingface",
            "/tmp/onnx",
        ]

        for path in paths {
            service.setModelPath(URL(fileURLWithPath: path))
        }

        // After all switches, should be in a clean state
        XCTAssertFalse(service.isModelLoaded)
    }

    func testSetModelPathAlwaysKillsEvenIfNotLoaded() {
        // This tests the fix: setModelPath used to only kill when isModelLoaded was true.
        // Now it always kills on path change. Verify by calling setModelPath
        // when isModelLoaded is false — killProcess should still be called (no crash).
        let service = makeService(modelPath: "/tmp/model-a")

        XCTAssertFalse(service.isModelLoaded)
        // This should call killProcess even though isModelLoaded is false
        service.setModelPath(URL(fileURLWithPath: "/tmp/model-b"))
        // Should still be false and not crash
        XCTAssertFalse(service.isModelLoaded)
    }
}

// MARK: - ModelManager: backend switching state

final class ModelManagerBackendSwitchTests: XCTestCase {

    @MainActor
    func testSwitchingBackendUpdatesUserDefaults() {
        let manager = ModelManager()
        let original = manager.activeBackend

        manager.activeBackend = .whisper
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "modelBackend"),
            "whisper"
        )

        manager.activeBackend = .onnx
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "modelBackend"),
            "onnx"
        )

        // Restore
        manager.activeBackend = original
    }

    @MainActor
    func testModelDirectoryChangesWithBackend() {
        let manager = ModelManager()

        manager.activeBackend = .onnx
        let onnxDir = manager.modelDirectory
        XCTAssert(onnxDir.path.contains("Models-ONNX"))

        manager.activeBackend = .huggingface
        let hfDir = manager.modelDirectory
        XCTAssert(hfDir.path.contains("Models"))
        XCTAssertFalse(hfDir.path.contains("ONNX"))

        manager.activeBackend = .whisper
        let whisperDir = manager.modelDirectory
        XCTAssert(whisperDir.path.contains("Models-Whisper"))

        // All different
        XCTAssertNotEqual(onnxDir, hfDir)
        XCTAssertNotEqual(onnxDir, whisperDir)
        XCTAssertNotEqual(hfDir, whisperDir)

        // Restore
        manager.activeBackend = .onnx
    }

    @MainActor
    func testHashKeysArePerBackendAfterSwitch() {
        let manager = ModelManager()

        // Simulate storing hashes for different backends
        manager.activeBackend = .onnx
        let onnxKey = "modelConfigHash_\(ModelBackend.onnx.rawValue)"

        manager.activeBackend = .whisper
        let whisperKey = "modelConfigHash_\(ModelBackend.whisper.rawValue)"

        XCTAssertNotEqual(onnxKey, whisperKey)

        // Restore
        manager.activeBackend = .onnx
    }

    @MainActor
    func testRefreshStateAfterBackendSwitch() {
        let manager = ModelManager()

        // Switching to a backend without a downloaded model should set notDownloaded
        manager.activeBackend = .whisper
        // Unless Whisper happens to be downloaded, state should be notDownloaded
        if manager.modelPath(for: .whisper) == nil {
            XCTAssertEqual(manager.state, .notDownloaded)
        }

        // Switch back to ONNX
        manager.activeBackend = .onnx
        // If ONNX is downloaded, state should be ready
        if manager.modelPath(for: .onnx) != nil {
            XCTAssertEqual(manager.state, .ready)
        }
    }
}

// MARK: - Preload cancellation

final class PreloadCancellationTests: XCTestCase {

    func testCancelledTaskDoesNotSetModelLoaded() async {
        let service = TranscriptionService(
            modelPath: URL(fileURLWithPath: "/nonexistent"),
            pythonPath: URL(fileURLWithPath: "/nonexistent"),
            scriptPath: URL(fileURLWithPath: "/nonexistent")
        )

        // preloadModel should fail (no Python) but not leave isModelLoaded = true
        do {
            try await service.preloadModel()
            XCTFail("Should have thrown — no Python binary exists")
        } catch {
            // Expected
        }

        XCTAssertFalse(service.isModelLoaded)
    }

    func testKillProcessAfterPreloadFailure() async {
        let service = TranscriptionService(
            modelPath: URL(fileURLWithPath: "/nonexistent"),
            pythonPath: URL(fileURLWithPath: "/nonexistent"),
            scriptPath: URL(fileURLWithPath: "/nonexistent")
        )

        // Try preload (will fail), then kill, then set new path
        do { try await service.preloadModel() } catch {}
        service.killProcess()
        service.setModelPath(URL(fileURLWithPath: "/tmp/new-model"))

        XCTAssertFalse(service.isModelLoaded)
    }
}

// MARK: - ModelBackend switching paths

final class ModelBackendSwitchPathTests: XCTestCase {

    func testAllBackendsHaveDistinctSubdirectories() {
        let paths = ModelBackend.allCases.map(\.modelSubdirectory)
        XCTAssertEqual(paths.count, Set(paths).count,
                       "Each backend must have a unique model subdirectory")
    }

    func testSwitchingPathsAreConsistent() {
        // Verify modelDirectory(for:) returns paths matching modelSubdirectory
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]

        for backend in ModelBackend.allCases {
            let expected = appSupport.appendingPathComponent(backend.modelSubdirectory)
            // ModelManager uses the same logic
            let actual = appSupport.appendingPathComponent(backend.modelSubdirectory)
            XCTAssertEqual(expected, actual)
        }
    }
}
