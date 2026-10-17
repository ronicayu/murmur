import Foundation

// The messages between the app and the speech engine process
// (`MurmurEngine`). Each message is one line of JSON: requests on the
// engine's standard input, replies on its standard output.

struct EngineRequest: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        case preload
        case transcribe
        /// One piece of a long recording. The app cuts a long file and sends
        /// it a piece at a time, so a dictation can go in between.
        case transcribePiece
    }

    /// Chosen by the app; every reply to this request carries it.
    let id: Int
    let operation: Operation
    /// The audio file, for the transcriptions. For a piece, a 16 kHz mono WAV.
    var path: String?
    /// The language hint, for the transcriptions.
    var language: String?
    /// The samples to decode, for a piece. On the wire: `[lower, upper]`.
    var range: Range<Int>?
}

struct EngineReply: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The model is loaded. Ends a `preload`.
        case ready
        /// The transcript. Ends a transcription.
        case result
        /// The request failed. Ends it.
        case failure
    }

    enum Failure: String, Codable, Sendable {
        case modelNotFound
        case other
    }

    let id: Int
    let kind: Kind

    // .result
    var text: String?
    var language: String?
    var durationMs: Int?

    // .failure
    var failure: Failure?
    var message: String?
}

extension EngineReply {
    static func result(id: Int, _ result: TranscriptionResult) -> EngineReply {
        var reply = EngineReply(id: id, kind: .result)
        reply.text = result.text
        reply.language = result.language.rawValue
        reply.durationMs = result.durationMs
        return reply
    }

    /// The transcript of one piece of a long recording.
    static func pieceText(id: Int, _ text: String) -> EngineReply {
        var reply = EngineReply(id: id, kind: .result)
        reply.text = text
        return reply
    }

    static func failure(id: Int, _ error: Error) -> EngineReply {
        var reply = EngineReply(id: id, kind: .failure)
        switch error as? MurmurError {
        case .modelNotFound?:
            reply.failure = .modelNotFound
        case .transcriptionFailed(let message)?:
            reply.failure = .other
            reply.message = message
        default:
            reply.failure = .other
            reply.message = error.localizedDescription
        }
        return reply
    }

    /// The error the app throws for a `.failure` reply.
    var error: Error {
        switch failure {
        case .modelNotFound?: return MurmurError.modelNotFound
        default: return MurmurError.transcriptionFailed(message ?? "The speech engine failed")
        }
    }

    /// The transcript of a `.result` reply.
    var transcriptionResult: TranscriptionResult? {
        guard kind == .result, let text else { return nil }
        return TranscriptionResult(
            text: text,
            language: language.flatMap(DetectedLanguage.init(rawValue:)) ?? .unknown,
            durationMs: durationMs ?? 0
        )
    }
}

enum EngineWire {
    /// `value` as one line, newline included. JSON never holds a raw newline.
    static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(line.utf8))
    }
}
