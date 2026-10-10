import XCTest
@testable import Murmur

/// The client's side of the engine process, against stand-in helpers: small
/// shell scripts that speak the line protocol. No model and no speech library.
final class EngineProcessClientTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// A client whose helper is `/bin/sh` running `script`. The script reads
    /// request lines from standard input; `id` extracts a request's id.
    private func makeClient(_ script: String, idleSeconds: TimeInterval = 300) -> EngineProcessClient {
        let prelude = #"id() { printf '%s' "$1" | sed -E 's/.*"id":([0-9]+).*/\1/'; }"# + "\n"
        return EngineProcessClient(
            launch: .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", prelude + script]),
            idleSeconds: idleSeconds
        )
    }

    private let audio = URL(fileURLWithPath: "/tmp/some audio.wav")

    // MARK: Replies

    func test_transcribe_returnsTheResultOfTheHelper() async throws {
        let client = makeClient(#"""
        while IFS= read -r line; do
          printf '{"id":%s,"kind":"result","text":"你好 world","language":"zh","durationMs":42}\n' "$(id "$line")"
        done
        """#)

        let result = try await client.transcribe(audioURL: audio, language: "zh,en")

        XCTAssertEqual(result.text, "你好 world")
        XCTAssertEqual(result.language, .chinese)
        XCTAssertEqual(result.durationMs, 42)
    }

    func test_request_carriesTheOperationPathAndLanguage() async throws {
        let log = directory.appendingPathComponent("requests.log")
        let client = makeClient(#"""
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "\#(log.path)"
          printf '{"id":%s,"kind":"result","text":"x","language":"en","durationMs":1}\n' "$(id "$line")"
        done
        """#)

        _ = try await client.transcribe(audioURL: audio, language: "zh,en")

        let sent = try EngineWire.decode(
            EngineRequest.self,
            from: String(contentsOf: log, encoding: .utf8).trimmingCharacters(in: .newlines)
        )
        XCTAssertEqual(sent.operation, .transcribe)
        XCTAssertEqual(sent.path, audio.path)
        XCTAssertEqual(sent.language, "zh,en")
    }

    func test_transcribeLong_reportsProgressBeforeTheResult() async throws {
        let client = makeClient(#"""
        while IFS= read -r line; do
          n="$(id "$line")"
          printf '{"id":%s,"kind":"progress","currentChunk":1,"totalChunks":2,"partialText":"one"}\n' "$n"
          printf '{"id":%s,"kind":"progress","currentChunk":2,"totalChunks":2,"partialText":"one two"}\n' "$n"
          printf '{"id":%s,"kind":"result","text":"one two","language":"en","durationMs":5}\n' "$n"
        done
        """#)
        let progress = LockedList<String>()

        let result = try await client.transcribeLong(audioURL: audio, language: "en") { update in
            progress.append("\(update.currentChunk)/\(update.totalChunks) \(update.partialText)")
        }

        XCTAssertEqual(result.text, "one two")
        XCTAssertEqual(progress.values, ["1/2 one", "2/2 one two"])
    }

    func test_preload_endsWithTheReadyReply() async throws {
        let client = makeClient(#"""
        while IFS= read -r line; do printf '{"id":%s,"kind":"ready"}\n' "$(id "$line")"; done
        """#)

        try await client.preloadModel()
    }

    func test_failureReply_modelNotFound_isThrownAsModelNotFound() async {
        let client = makeClient(#"""
        while IFS= read -r line; do printf '{"id":%s,"kind":"failure","failure":"modelNotFound"}\n' "$(id "$line")"; done
        """#)

        do {
            try await client.preloadModel()
            XCTFail("expected modelNotFound")
        } catch MurmurError.modelNotFound {
            // expected
        } catch {
            XCTFail("expected modelNotFound, got \(error)")
        }
    }

    func test_failureReply_other_carriesTheMessage() async {
        let client = makeClient(#"""
        while IFS= read -r line; do
          printf '{"id":%s,"kind":"failure","failure":"other","message":"bad audio"}\n' "$(id "$line")"
        done
        """#)

        do {
            _ = try await client.transcribe(audioURL: audio, language: "en")
            XCTFail("expected a failure")
        } catch MurmurError.transcriptionFailed(let message) {
            XCTAssertEqual(message, "bad audio")
        } catch {
            XCTFail("expected transcriptionFailed, got \(error)")
        }
    }

    func test_linesThatAreNotReplies_areIgnored() async throws {
        let client = makeClient(#"""
        while IFS= read -r line; do
          printf 'a log line that is not JSON\n'
          printf '{"id":%s,"kind":"result","text":"ok","language":"en","durationMs":1}\n' "$(id "$line")"
        done
        """#)

        let result = try await client.transcribe(audioURL: audio, language: "en")

        XCTAssertEqual(result.text, "ok")
    }

    // MARK: The life of the process

    func test_helperThatExits_failsTheRequest_andTheNextRequestStartsANewOne() async throws {
        // The first helper process exits without a reply; later ones answer.
        let marker = directory.appendingPathComponent("started-once")
        let client = makeClient(#"""
        if [ ! -e "\#(marker.path)" ]; then : > "\#(marker.path)"; read -r line; exit 3; fi
        while IFS= read -r line; do
          printf '{"id":%s,"kind":"result","text":"second process","language":"en","durationMs":1}\n' "$(id "$line")"
        done
        """#)

        do {
            _ = try await client.transcribe(audioURL: audio, language: "en")
            XCTFail("the request to a helper that exits must fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }

        let result = try await client.transcribe(audioURL: audio, language: "en")
        XCTAssertEqual(result.text, "second process")
    }

    func test_helperThatCannotBeStarted_failsTheRequest() async {
        let client = EngineProcessClient(
            launch: .init(executable: directory.appendingPathComponent("no-such-helper"), arguments: [])
        )

        do {
            try await client.preloadModel()
            XCTFail("expected an error")
        } catch {
            // expected
        }
        let running = await client.isRunning
        XCTAssertFalse(running)
    }

    func test_cancellingARequest_endsTheHelper_andThrowsCancellation() async throws {
        // This helper never answers, like a decode that takes too long.
        let pidFile = directory.appendingPathComponent("pid")
        let client = makeClient(#"""
        echo $$ > "\#(pidFile.path)"
        while IFS= read -r line; do :; done
        """#)

        let request = Task { try await client.transcribe(audioURL: audio, language: "en") }
        let started = await eventually { FileManager.default.fileExists(atPath: pidFile.path) }
        XCTAssertTrue(started)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        request.cancel()

        do {
            _ = try await request.value
            XCTFail("a cancelled request must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let gone = await eventually { kill(pid, 0) != 0 }
        XCTAssertTrue(gone, "the helper must not keep decoding for a caller that left")
        let running = await client.isRunning
        XCTAssertFalse(running)
    }

    func test_unloadModel_endsTheHelper() async throws {
        let client = makeClient(#"""
        while IFS= read -r line; do printf '{"id":%s,"kind":"ready"}\n' "$(id "$line")"; done
        """#)
        try await client.preloadModel()
        let runningBefore = await client.isRunning
        XCTAssertTrue(runningBefore)

        await client.unloadModel()

        let runningAfter = await client.isRunning
        XCTAssertFalse(runningAfter)
    }

    func test_helperIsEnded_afterTheIdleTime_andStartedAgainByTheNextRequest() async throws {
        let starts = directory.appendingPathComponent("starts")
        let client = makeClient(#"""
        echo start >> "\#(starts.path)"
        while IFS= read -r line; do printf '{"id":%s,"kind":"ready"}\n' "$(id "$line")"; done
        """#, idleSeconds: 0.2)

        try await client.preloadModel()
        let stopped = await eventually { await client.isRunning == false }
        XCTAssertTrue(stopped, "the helper holds the model; it must not outlive the idle time")

        try await client.preloadModel()
        let lines = try String(contentsOf: starts, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }

    func test_clientThatGoesAway_endsItsHelper() async throws {
        let pidFile = directory.appendingPathComponent("pid")
        var client: EngineProcessClient? = makeClient(#"""
        echo $$ > "\#(pidFile.path)"
        while IFS= read -r line; do printf '{"id":%s,"kind":"ready"}\n' "$(id "$line")"; done
        """#)
        try await client?.preloadModel()
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), 0, "Precondition: the helper is running")

        client = nil

        let gone = await eventually { kill(pid, 0) != 0 }
        XCTAssertTrue(gone, "a helper holds gigabytes; it must not outlive its client")
    }

    func test_twoClients_doNotHoldEachOtherUp() async throws {
        // The first helper stays alive and silent while the second one works.
        let silent = makeClient("while IFS= read -r line; do :; done")
        let waiting = Task { try await silent.preloadModel() }
        let answering = makeClient(#"""
        while IFS= read -r line; do printf '{"id":%s,"kind":"ready"}\n' "$(id "$line")"; done
        """#)

        try await answering.preloadModel()

        waiting.cancel()
        _ = try? await waiting.value
    }

    // MARK: Lines

    func test_lineSplitter_joinsALineThatArrivesInPieces() {
        let splitter = LineSplitter()

        XCTAssertEqual(splitter.lines(adding: Data("{\"a\":".utf8)), [])
        XCTAssertEqual(splitter.lines(adding: Data("1}\n{\"b\":2}\n{\"c\"".utf8)), ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(splitter.lines(adding: Data(":3}\n".utf8)), ["{\"c\":3}"])
    }

    func test_lineSplitter_keepsMultibyteCharactersCutBetweenPieces() {
        let splitter = LineSplitter()
        let bytes = Array("你好\n".utf8)

        XCTAssertEqual(splitter.lines(adding: Data(bytes[0..<2])), [])
        XCTAssertEqual(splitter.lines(adding: Data(bytes[2...])), ["你好"])
    }

    // MARK: Finding the helper

    func test_helperExecutable_isNil_whenNoHelperIsNextToTheExecutable() {
        XCTAssertNil(EngineProcessClient.helperExecutable(isExecutable: { _ in false }))
    }

    func test_makeDefault_withoutAHelper_usesTheEngineInProcess() {
        // The test runner has no MurmurEngine next to it.
        let service = EngineProcessClient.makeDefault(modelDirectory: directory)
        XCTAssertTrue(service is Qwen3TranscriptionService)
    }
}

/// Waits up to 5 s for `condition`.
private func eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

private final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    var values: [Element] { lock.withLock { items } }

    func append(_ item: Element) {
        lock.withLock { items.append(item) }
    }
}

// MARK: - The helper's side

final class EngineServerTests: XCTestCase {

    private func lines(_ requests: [EngineRequest]) -> AsyncStream<String> {
        AsyncStream { continuation in
            for request in requests {
                continuation.yield(String(decoding: try! EngineWire.line(request), as: UTF8.self))
            }
            continuation.finish()
        }
    }

    private func serve(_ service: any TranscriptionServiceProtocol, _ requests: [EngineRequest]) async throws -> [EngineReply] {
        let written = LockedList<Data>()
        await EngineServer(service: service) { written.append($0) }.run(lines: lines(requests))
        return try written.values.map {
            try EngineWire.decode(EngineReply.self, from: String(decoding: $0, as: UTF8.self))
        }
    }

    func test_transcribe_repliesWithTheResult() async throws {
        let service = SpyTranscriptionService()
        service.stubbedResult = TranscriptionResult(text: "hello", language: .english, durationMs: 7)
        var request = EngineRequest(id: 4, operation: .transcribe)
        request.path = "/tmp/a.wav"
        request.language = "en"

        let replies = try await serve(service, [request])

        XCTAssertEqual(replies, [.result(id: 4, service.stubbedResult)])
        XCTAssertEqual(replies.first?.transcriptionResult?.text, "hello")
    }

    func test_transcribeLong_repliesWithProgressThenTheResult() async throws {
        let service = SpyTranscriptionService()
        var request = EngineRequest(id: 9, operation: .transcribeLong)
        request.path = "/tmp/a.wav"

        let replies = try await serve(service, [request])

        XCTAssertEqual(replies.map(\.kind), [.progress, .result])
        XCTAssertEqual(replies.map(\.id), [9, 9])
        XCTAssertEqual(replies.first?.partialText, "partial")
    }

    func test_preload_repliesReady() async throws {
        let replies = try await serve(SpyTranscriptionService(), [EngineRequest(id: 1, operation: .preload)])
        XCTAssertEqual(replies, [EngineReply(id: 1, kind: .ready)])
    }

    func test_errorOfTheService_isAFailureReply_andTheServerGoesOn() async throws {
        let service = SpyTranscriptionService()
        service.stubbedError = MurmurError.modelNotFound
        var first = EngineRequest(id: 1, operation: .transcribe)
        first.path = "/tmp/a.wav"

        let replies = try await serve(service, [first, EngineRequest(id: 2, operation: .preload)])

        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies[0].kind, .failure)
        XCTAssertEqual(replies[0].failure, .modelNotFound)
        XCTAssertEqual(replies[1], EngineReply(id: 2, kind: .ready))
    }

    func test_transcriptionWithoutAPath_isAFailure() async throws {
        let replies = try await serve(SpyTranscriptionService(), [EngineRequest(id: 3, operation: .transcribe)])

        XCTAssertEqual(replies.map(\.kind), [.failure])
    }

    func test_failureReply_roundTripsTheErrorTheAppThrows() {
        guard case MurmurError.modelNotFound = EngineReply.failure(id: 1, MurmurError.modelNotFound).error else {
            return XCTFail("modelNotFound must stay modelNotFound")
        }
        guard case MurmurError.transcriptionFailed(let message) =
                EngineReply.failure(id: 1, MurmurError.transcriptionFailed("bad audio")).error else {
            return XCTFail("expected transcriptionFailed")
        }
        XCTAssertEqual(message, "bad audio")
    }
}
