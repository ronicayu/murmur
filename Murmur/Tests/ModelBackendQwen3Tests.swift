import XCTest
@testable import Murmur

final class ModelBackendQwen3Tests: XCTestCase {

    func test_qwen3_isPartOfAllCases() {
        XCTAssertTrue(ModelBackend.allCases.contains(.qwen3))
    }

    func test_qwen3_rawValue() {
        XCTAssertEqual(ModelBackend.qwen3.rawValue, "qwen3")
    }

    func test_qwen3_modelRepo() {
        XCTAssertEqual(
            ModelBackend.qwen3.modelRepo,
            "csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"
        )
    }

    func test_qwen3_modelSubdirectory_isUnique() {
        XCTAssertEqual(ModelBackend.qwen3.modelSubdirectory, "Murmur/Models-Qwen3ASR")
        let subdirs = ModelBackend.allCases.map(\.modelSubdirectory)
        XCTAssertEqual(Set(subdirs).count, subdirs.count, "modelSubdirectory must be unique per backend")
    }

    func test_qwen3_requiresHFLogin_isFalse() {
        XCTAssertFalse(ModelBackend.qwen3.requiresHFLogin)
    }

    func test_qwen3_requiredFiles() {
        XCTAssertEqual(
            Set(ModelBackend.qwen3.requiredFiles),
            Set([
                "conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx",
                "tokenizer/vocab.json", "tokenizer/merges.txt", "tokenizer/tokenizer_config.json",
            ])
        )
    }

    func test_qwen3_allowPatterns_coverRequiredFiles_andExcludeTestWavs() {
        let patterns = ModelBackend.qwen3.allowPatterns ?? []
        for file in ModelBackend.qwen3.requiredFiles {
            let covered = patterns.contains(file)
                || (file.hasPrefix("tokenizer/") && patterns.contains("tokenizer/*"))
            XCTAssertTrue(covered, "\(file) is required but no allow pattern downloads it")
        }
        XCTAssertFalse(patterns.contains { $0.contains("test_wavs") },
                       "test_wavs/* should be excluded to save bandwidth")
    }

    func test_qwen3_isSmallerThanFireRed() {
        XCTAssertLessThan(ModelBackend.qwen3.requiredDiskSpace, ModelBackend.fireRed.requiredDiskSpace)
    }
}
