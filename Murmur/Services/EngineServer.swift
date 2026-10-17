import Foundation

/// The engine process's side of `EngineProtocol`: takes requests one at a
/// time, runs them on the speech service, and writes the replies.
struct EngineServer {
    let service: any TranscriptionServiceProtocol
    /// Writes one reply line. Called from one task at a time.
    let write: @Sendable (Data) -> Void

    /// Serves `lines` until the sequence ends, which is when the app closes
    /// the pipe or is gone.
    func run<Lines: AsyncSequence>(lines: Lines) async where Lines.Element == String {
        do {
            for try await line in lines {
                guard let request = try? EngineWire.decode(EngineRequest.self, from: line) else { continue }
                await handle(request)
            }
        } catch {
            // The input broke: there is nobody left to serve.
        }
    }

    func handle(_ request: EngineRequest) async {
        do {
            switch request.operation {
            case .preload:
                try await service.preloadModel()
                send(EngineReply(id: request.id, kind: .ready))
            case .transcribe:
                let result = try await service.transcribe(
                    audioURL: try audioURL(of: request), language: request.language ?? ""
                )
                send(.result(id: request.id, result))
            case .transcribePiece:
                guard let range = request.range else {
                    throw MurmurError.transcriptionFailed("The request names no piece")
                }
                let text = try await service.transcribePiece(
                    audioURL: try audioURL(of: request), range: range, language: request.language ?? ""
                )
                send(.pieceText(id: request.id, text))
            }
        } catch {
            send(.failure(id: request.id, error))
        }
    }

    private func audioURL(of request: EngineRequest) throws -> URL {
        guard let path = request.path else {
            throw MurmurError.transcriptionFailed("The request names no audio file")
        }
        return URL(fileURLWithPath: path)
    }

    private func send(_ reply: EngineReply) {
        if let line = try? EngineWire.line(reply) { write(line) }
    }
}
