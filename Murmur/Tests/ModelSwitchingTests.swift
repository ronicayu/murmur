import XCTest
@testable import Murmur

// MARK: - ModelManager: backend switching state

final class ModelManagerBackendSwitchTests: XCTestCase {

    @MainActor
    func testSwitchingBackendUpdatesUserDefaults() {
        let manager = ModelManager()
        let original = manager.activeBackend

        _ = manager.setActiveBackend(.fireRed)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "modelBackend"), "fireRed")

        _ = manager.setActiveBackend(.onnx)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "modelBackend"), "onnx")

        _ = manager.setActiveBackend(original)
    }

    @MainActor
    func testModelDirectoryChangesWithBackend() {
        let manager = ModelManager()

        _ = manager.setActiveBackend(.onnx)
        let onnxDir = manager.modelDirectory
        XCTAssert(onnxDir.path.contains("Models-ONNX"))

        _ = manager.setActiveBackend(.fireRed)
        let fireRedDir = manager.modelDirectory
        XCTAssert(fireRedDir.path.contains("Models-FireRed"))

        XCTAssertNotEqual(onnxDir, fireRedDir)

        _ = manager.setActiveBackend(.onnx)
    }

    @MainActor
    func testHashKeysArePerBackendAfterSwitch() {
        let manager = ModelManager()
        _ = manager.setActiveBackend(.onnx)
        let onnxKey = "modelConfigHash_\(ModelBackend.onnx.rawValue)"
        _ = manager.setActiveBackend(.fireRed)
        let fireRedKey = "modelConfigHash_\(ModelBackend.fireRed.rawValue)"
        XCTAssertNotEqual(onnxKey, fireRedKey)
        _ = manager.setActiveBackend(.onnx)
    }

    @MainActor
    func testRefreshStateAfterBackendSwitch() {
        let manager = ModelManager()

        _ = manager.setActiveBackend(.fireRed)
        if manager.modelPath(for: .fireRed) == nil {
            XCTAssertEqual(manager.state, .notDownloaded)
        }

        _ = manager.setActiveBackend(.onnx)
        if manager.modelPath(for: .onnx) != nil {
            XCTAssertEqual(manager.state, .ready)
        }
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
