import XCTest
@testable import Murmur

final class ModelBackendFireRedTests: XCTestCase {

    func test_fireRed_isPartOfAllCases() {
        XCTAssertTrue(ModelBackend.allCases.contains(.fireRed))
    }

    func test_fireRed_rawValue() {
        XCTAssertEqual(ModelBackend.fireRed.rawValue, "fireRed")
    }

    func test_fireRed_displayName() {
        XCTAssertEqual(ModelBackend.fireRed.displayName, "FireRed (Chinese-first)")
    }

    func test_fireRed_shortName() {
        XCTAssertEqual(ModelBackend.fireRed.shortName, "FireRed")
    }

    func test_fireRed_modelRepo() {
        XCTAssertEqual(
            ModelBackend.fireRed.modelRepo,
            "csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26"
        )
    }

    func test_fireRed_modelSubdirectory() {
        XCTAssertEqual(ModelBackend.fireRed.modelSubdirectory, "Murmur/Models-FireRed")
    }

    func test_fireRed_modelSubdirectory_isUnique() {
        let subdirs = ModelBackend.allCases.map(\.modelSubdirectory)
        XCTAssertEqual(Set(subdirs).count, subdirs.count, "modelSubdirectory must be unique per backend")
    }

    func test_fireRed_requiresHFLogin_isFalse() {
        XCTAssertFalse(ModelBackend.fireRed.requiresHFLogin)
    }

    func test_fireRed_requiredFiles() {
        XCTAssertEqual(
            Set(ModelBackend.fireRed.requiredFiles),
            Set(["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"])
        )
    }

    func test_fireRed_allowPatterns_excludesTestWavs() {
        let patterns = ModelBackend.fireRed.allowPatterns ?? []
        XCTAssertTrue(patterns.contains("encoder.int8.onnx"))
        XCTAssertTrue(patterns.contains("decoder.int8.onnx"))
        XCTAssertTrue(patterns.contains("tokens.txt"))
        XCTAssertFalse(patterns.contains { $0.contains("test_wavs") },
                       "test_wavs/* should be excluded to save bandwidth")
    }

    func test_fireRed_requiredDiskSpace_isApprox1_3GB() {
        XCTAssertEqual(ModelBackend.fireRed.requiredDiskSpace, 1_300_000_000)
    }

    func test_fireRed_sizeDescription() {
        XCTAssertEqual(ModelBackend.fireRed.sizeDescription, "~1.24 GB")
    }

    func test_fireRed_description_mentionsChineseAndFallback() {
        let d = ModelBackend.fireRed.description.lowercased()
        XCTAssertTrue(d.contains("chinese"), "description must mention Chinese: \(d)")
        XCTAssertTrue(d.contains("cohere") || d.contains("fall back") || d.contains("fallback"),
                      "description must explain Cohere fallback: \(d)")
    }
}
