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

    func test_hfBackend_toggleOn_zh_routesToFireRed() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .huggingface, useFireRedForChinese: true,
                                      language: "zh", version: .v1FullPass),
            .fireRed
        )
    }

    func test_hfBackend_toggleOn_en_routesToHF() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .huggingface, useFireRedForChinese: true,
                                      language: "en", version: .v1FullPass),
            .existing(.huggingface)
        )
    }

    func test_whisperBackend_toggleOn_zh_stillRoutesToWhisper() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .whisper, useFireRedForChinese: true,
                                      language: "zh", version: .v1FullPass),
            .existing(.whisper)
        )
    }

    func test_whisperBackend_zh_routesToWhisper() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .whisper, useFireRedForChinese: false,
                                      language: "zh", version: .v1FullPass),
            .existing(.whisper)
        )
    }
}
