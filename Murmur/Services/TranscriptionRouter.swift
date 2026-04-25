import Foundation

/// Pure routing decision: given the user's settings and the request shape,
/// pick which transcription backend implementation handles this audio.
///
/// No I/O, no async, no logging — easy to test exhaustively.
enum TranscriptionRouter {

    /// V1 = full-pass (record then transcribe); V3 = streaming.
    /// V3 always uses Cohere because FireRed has no streaming mode.
    enum TranscriptionVersion: Sendable {
        case v1FullPass
        case v3Streaming
    }

    /// Where to send the request.
    enum BackendChoice: Equatable, Sendable {
        case fireRed
        case cohereStreaming
        case cohereONNX
        case existing(ModelBackend)
    }

    static func route(
        activeBackend: ModelBackend,
        useFireRedForChinese: Bool,
        language: String,
        version: TranscriptionVersion
    ) -> BackendChoice {
        if version == .v3Streaming {
            return .cohereStreaming
        }

        if activeBackend == .fireRed {
            if language == "zh" || language == "en" {
                return .fireRed
            }
            return .cohereONNX
        }

        if (activeBackend == .onnx || activeBackend == .huggingface)
            && useFireRedForChinese
            && language == "zh"
        {
            return .fireRed
        }

        return .existing(activeBackend)
    }
}
