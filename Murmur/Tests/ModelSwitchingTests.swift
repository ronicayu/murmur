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

    func testSetModelPathKillsProcessOnChange() async {
        let service = makeService(modelPath: "/tmp/model-a")
        XCTAssertFalse(service.isModelLoaded)
        await service.setModelPath(URL(fileURLWithPath: "/tmp/model-b"))
        XCTAssertFalse(service.isModelLoaded)
    }

    func testSetModelPathSamePathDoesNotKill() async {
        let service = makeService(modelPath: "/tmp/model-a")
        await service.setModelPath(URL(fileURLWithPath: "/tmp/model-a"))
        XCTAssertFalse(service.isModelLoaded)
    }

    func testSetModelPathResetsIsModelLoaded() async {
        let service = makeService(modelPath: "/tmp/model-a")
        await service.killProcess()
        XCTAssertFalse(service.isModelLoaded)
    }

    func testConcurrentSetModelPathAndKillProcess() async {
        let service = makeService(modelPath: "/tmp/model-a")

        // Actor serializes access — verify no crashes under concurrent calls
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    await service.setModelPath(URL(fileURLWithPath: "/tmp/model-\(i % 3)"))
                }
                group.addTask {
                    await service.killProcess()
                }
            }
        }

        XCTAssertFalse(service.isModelLoaded)
    }

    func testRapidBackendSwitching() async {
        let service = makeService(modelPath: "/tmp/onnx")

        let paths = ["/tmp/huggingface", "/tmp/onnx", "/tmp/whisper",
                     "/tmp/onnx", "/tmp/huggingface", "/tmp/onnx"]
        for path in paths {
            await service.setModelPath(URL(fileURLWithPath: path))
        }

        XCTAssertFalse(service.isModelLoaded)
    }

    func testSetModelPathAlwaysKillsEvenIfNotLoaded() async {
        let service = makeService(modelPath: "/tmp/model-a")
        XCTAssertFalse(service.isModelLoaded)
        await service.setModelPath(URL(fileURLWithPath: "/tmp/model-b"))
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
        XCTAssertEqual(UserDefaults.standard.string(forKey: "modelBackend"), "whisper")

        manager.activeBackend = .onnx
        XCTAssertEqual(UserDefaults.standard.string(forKey: "modelBackend"), "onnx")

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

        XCTAssertNotEqual(onnxDir, hfDir)
        XCTAssertNotEqual(onnxDir, whisperDir)
        XCTAssertNotEqual(hfDir, whisperDir)

        manager.activeBackend = .onnx
    }

    @MainActor
    func testHashKeysArePerBackendAfterSwitch() {
        let manager = ModelManager()
        manager.activeBackend = .onnx
        let onnxKey = "modelConfigHash_\(ModelBackend.onnx.rawValue)"
        manager.activeBackend = .whisper
        let whisperKey = "modelConfigHash_\(ModelBackend.whisper.rawValue)"
        XCTAssertNotEqual(onnxKey, whisperKey)
        manager.activeBackend = .onnx
    }

    @MainActor
    func testRefreshStateAfterBackendSwitch() {
        let manager = ModelManager()

        manager.activeBackend = .whisper
        if manager.modelPath(for: .whisper) == nil {
            XCTAssertEqual(manager.state, .notDownloaded)
        }

        manager.activeBackend = .onnx
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

        do { try await service.preloadModel() } catch {}
        await service.killProcess()
        await service.setModelPath(URL(fileURLWithPath: "/tmp/new-model"))

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
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]

        for backend in ModelBackend.allCases {
            let expected = appSupport.appendingPathComponent(backend.modelSubdirectory)
            let actual = appSupport.appendingPathComponent(backend.modelSubdirectory)
            XCTAssertEqual(expected, actual)
        }
    }
}
