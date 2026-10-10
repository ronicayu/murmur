import XCTest
@testable import Murmur

final class TranscriptionRouterTests: XCTestCase {

    typealias Choice = TranscriptionRouter.BackendChoice

    func test_v3Streaming_alwaysRoutesToCohere_evenWithFireRedActive() {
        let c = TranscriptionRouter.route(
            activeBackend: .fireRed, useFireRedForChinese: true,
            language: "zh", version: .v3Streaming
        )
        XCTAssertEqual(c, .cohereStreaming)
    }

    func test_v3Streaming_alwaysRoutesToCohere_withToggleOn() {
        let c = TranscriptionRouter.route(
            activeBackend: .onnx, useFireRedForChinese: true,
            language: "zh", version: .v3Streaming
        )
        XCTAssertEqual(c, .cohereStreaming)
    }

    func test_fireRedBackend_zh_routesToFireRed() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .fireRed, useFireRedForChinese: false,
                                      language: "zh", version: .v1FullPass),
            .fireRed
        )
    }

    func test_fireRedBackend_en_routesToFireRed() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .fireRed, useFireRedForChinese: false,
                                      language: "en", version: .v1FullPass),
            .fireRed
        )
    }

    func test_fireRedBackend_ja_fallsBackToCohereONNX() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .fireRed, useFireRedForChinese: false,
                                      language: "ja", version: .v1FullPass),
            .cohereONNX
        )
    }

    func test_fireRedBackend_fr_fallsBackToCohereONNX() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .fireRed, useFireRedForChinese: false,
                                      language: "fr", version: .v1FullPass),
            .cohereONNX
        )
    }

    func test_onnxBackend_toggleOn_zh_routesToFireRed() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .onnx, useFireRedForChinese: true,
                                      language: "zh", version: .v1FullPass),
            .fireRed
        )
    }

    func test_onnxBackend_toggleOn_en_routesToOnnx() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .onnx, useFireRedForChinese: true,
                                      language: "en", version: .v1FullPass),
            .existing(.onnx)
        )
    }

    func test_onnxBackend_toggleOn_ja_routesToOnnx() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .onnx, useFireRedForChinese: true,
                                      language: "ja", version: .v1FullPass),
            .existing(.onnx)
        )
    }

    func test_onnxBackend_toggleOff_zh_routesToOnnx() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .onnx, useFireRedForChinese: false,
                                      language: "zh", version: .v1FullPass),
            .existing(.onnx)
        )
    }

    // .huggingface and .whisper backends were removed in v0.3.1; the tests
    // that exercised those routes are deleted with them. The router code
    // still works correctly for any future case via the fall-through
    // `.existing(activeBackend)` path — covered indirectly by the
    // FireRed/ONNX cases above.

    // MARK: - Qwen3-ASR backend

    func test_qwen3Backend_zh_routesToQwen3() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .qwen3, useFireRedForChinese: false,
                                      language: "zh", version: .v1FullPass),
            .qwen3
        )
    }

    func test_qwen3Backend_en_routesToQwen3() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .qwen3, useFireRedForChinese: false,
                                      language: "en", version: .v1FullPass),
            .qwen3
        )
    }

    func test_qwen3Backend_ja_fallsBackToCohereONNX() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .qwen3, useFireRedForChinese: false,
                                      language: "ja", version: .v1FullPass),
            .cohereONNX
        )
    }

    func test_qwen3Backend_ignoresFireRedToggle() {
        // The toggle only applies under the Standard backend; a stale ON value
        // must not pull Chinese audio away from Qwen3.
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .qwen3, useFireRedForChinese: true,
                                      language: "zh", version: .v1FullPass),
            .qwen3
        )
    }

    func test_v3Streaming_alwaysRoutesToCohere_evenWithQwen3Active() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .qwen3, useFireRedForChinese: false,
                                      language: "zh", version: .v3Streaming),
            .cohereStreaming
        )
    }
}
