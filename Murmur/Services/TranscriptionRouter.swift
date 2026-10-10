import Foundation

/// Pure routing decision: given the user's settings and the request shape,
/// pick which transcription backend implementation handles this audio.
///
/// No I/O, no async, no logging — easy to test exhaustively.
enum TranscriptionRouter {

    /// V1 = full-pass (record then transcribe); V3 = streaming.
    /// V3 uses Cohere unless Qwen3-ASR is the active engine (see `route`).
    enum TranscriptionVersion: Sendable {
        case v1FullPass
        case v3Streaming
    }

    /// Where to send the request.
    enum BackendChoice: Equatable, Sendable {
        case fireRed
        case qwen3
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
            // V3 "streaming" is chunked offline transcription, so any fast
            // offline model can serve it. Qwen3-ASR is fast enough (several
            // times quicker than Cohere per chunk); FireRed is not, so it
            // still hands streaming to Cohere.
            if activeBackend == .qwen3 && (language == "zh" || language == "en") {
                return .qwen3
            }
            return .cohereStreaming
        }

        if activeBackend == .fireRed {
            if language == "zh" || language == "en" {
                return .fireRed
            }
            return .cohereONNX
        }

        if activeBackend == .qwen3 {
            if language == "zh" || language == "en" {
                return .qwen3
            }
            return .cohereONNX
        }

        if activeBackend == .onnx
            && useFireRedForChinese
            && language == "zh"
        {
            return .fireRed
        }

        return .existing(activeBackend)
    }
}
