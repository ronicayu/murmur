import XCTest
import AVFoundation
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

    /// A client whose helper is `/bin/sh` (or `executable`, a link to it)
    /// running `script`. The script reads request lines from standard input;
    /// `id` extracts a request's id.
    private func makeClient(
        _ script: String,
        idleSeconds: TimeInterval = 300,
        executable: URL = URL(fileURLWithPath: "/bin/sh")
    ) -> EngineProcessClient {
        let prelude = #"id() { printf '%s' "$1" | sed -E 's/.*"id":([0-9]+).*/\1/'; }"# + "\n"
        return EngineProcessClient(
            launch: .init(executable: executable, arguments: ["-c", prelude + script]),
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

    // MARK: Long files, a piece at a time

    /// A helper that logs each request's operation to `ops`, writes its pid
    /// to `launches` when it starts, and answers: `ready` to a preload,
    /// `p<first sample>` to a piece, `dictated` to a transcription. The
    /// first request whose operation is `hold` waits until `go` exists.
    private func makePieceClient(ops: URL, launches: URL, hold: String = "", go: URL? = nil) -> EngineProcessClient {
        let mark = directory.appendingPathComponent("held-\(UUID().uuidString)")
        let goPath = go?.path ?? "/nonexistent"
        return makeClient(#"""
        op() { printf '%s' "$1" | sed -E 's/.*"operation":"([A-Za-z]+)".*/\1/'; }
        lo() { printf '%s' "$1" | sed -E 's/.*"range":\[([0-9]+),.*/\1/'; }
        echo $$ >> "\#(launches.path)"
        while IFS= read -r line; do
          o="$(op "$line")"
          echo "$o" >> "\#(ops.path)"
          if [ "$o" = "\#(hold)" ] && [ ! -f "\#(mark.path)" ]; then
            : > "\#(mark.path)"
            while [ ! -f "\#(goPath)" ]; do sleep 0.05; done
          fi
          case "$o" in
            preload) printf '{"id":%s,"kind":"ready"}\n' "$(id "$line")" ;;
            transcribePiece) printf '{"id":%s,"kind":"result","text":"p%s"}\n' "$(id "$line")" "$(lo "$line")" ;;
            *) printf '{"id":%s,"kind":"result","text":"dictated","language":"en","durationMs":1}\n' "$(id "$line")" ;;
          esac
        done
        """#)
    }

    /// Speech 0–3 s and 6–9 s, silence between: two spans, one piece each.
    /// The 3 s silence is a paragraph break.
    private func writeTwoUtterances(sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) throws -> URL {
        let url = directory.appendingPathComponent("long-\(UUID().uuidString).wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * 9)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                let seconds = Double(i) / sampleRate
                let speaking = seconds < 3 || seconds >= 6
                buffer.floatChannelData![channel][i] = speaking ? 0.1 * sin(Float(i) * 0.05) : 0
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func lines(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func convertedCopies() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix(TemporaryAudio.prefix + "long_") })
    }

    func test_transcribeLong_sendsTheFileAPieceAtATime() async throws {
        let ops = directory.appendingPathComponent("ops")
        let client = makePieceClient(ops: ops, launches: directory.appendingPathComponent("launches"))
        let progress = LockedList<String>()

        let result = try await client.transcribeLong(audioURL: try writeTwoUtterances(), language: "en") { update in
            progress.append("\(update.currentChunk)/\(update.totalChunks) \(update.partialText)")
        }

        // The second span starts 0.3 s (margin) before its speech at 6 s.
        XCTAssertEqual(result.text, "p0\n\np91200")
        XCTAssertEqual(result.segments.map(\.start), [0, 6])
        XCTAssertEqual(result.segments.map(\.startsParagraph), [false, true])
        XCTAssertEqual(progress.values, ["1/2 p0", "2/2 p0\n\np91200"])
        XCTAssertEqual(lines(ops), ["preload", "transcribePiece", "transcribePiece"])
    }

    func test_dictationDuringAPiece_isSentBeforeTheFilesNextPiece() async throws {
        let ops = directory.appendingPathComponent("ops")
        let go = directory.appendingPathComponent("go")
        let client = makePieceClient(
            ops: ops, launches: directory.appendingPathComponent("launches"), hold: "transcribePiece", go: go)
        let file = Task { try await client.transcribeLong(audioURL: try self.writeTwoUtterances(), language: "en") { _ in } }
        let pieceSent = await eventually { self.lines(ops).count == 2 }
        XCTAssertTrue(pieceSent, "Precondition: the helper has the file's first piece")

        let dictation = Task { try await client.transcribe(audioURL: self.audio, language: "en") }
        let waiting = await eventually { await client.queuedRequestCount == 1 }
        XCTAssertTrue(waiting, "Precondition: the dictation waits for the piece")
        try Data().write(to: go)

        let dictated = try await boundedValue(of: dictation)
        _ = try await boundedValue(of: file)
        XCTAssertEqual(dictated.text, "dictated")
        XCTAssertEqual(lines(ops), ["preload", "transcribePiece", "transcribe", "transcribePiece"])
    }

    /// The file's waiting request is older, the dictation's newer: the
    /// dictation still goes first.
    func test_waitingDictation_goesAheadOfAnOlderFileRequest() async throws {
        let ops = directory.appendingPathComponent("ops")
        let go = directory.appendingPathComponent("go")
        let client = makePieceClient(
            ops: ops, launches: directory.appendingPathComponent("launches"), hold: "transcribe", go: go)
        let first = Task { try await client.transcribe(audioURL: self.audio, language: "en") }
        let firstSent = await eventually { self.lines(ops).count == 1 }
        XCTAssertTrue(firstSent, "Precondition: the helper has the first dictation")
        let file = Task { try await client.transcribeLong(audioURL: try self.writeTwoUtterances(), language: "en") { _ in } }
        let fileWaiting = await eventually { await client.queuedRequestCount == 1 }
        XCTAssertTrue(fileWaiting, "Precondition: the file's preload waits")
        let second = Task { try await client.transcribe(audioURL: self.audio, language: "en") }
        let bothWaiting = await eventually { await client.queuedRequestCount == 2 }
        XCTAssertTrue(bothWaiting, "Precondition: the second dictation waits behind the file")
        try Data().write(to: go)

        _ = try await boundedValue(of: first)
        _ = try await boundedValue(of: second)
        _ = try await boundedValue(of: file)
        XCTAssertEqual(lines(ops), ["transcribe", "transcribe", "preload", "transcribePiece", "transcribePiece"])
    }

    func test_cancellingALongTranscription_letsThePieceFinish_andKeepsTheHelper() async throws {
        let ops = directory.appendingPathComponent("ops")
        let launches = directory.appendingPathComponent("launches")
        let go = directory.appendingPathComponent("go")
        let client = makePieceClient(ops: ops, launches: launches, hold: "transcribePiece", go: go)
        let file = Task { try await client.transcribeLong(audioURL: try self.writeTwoUtterances(), language: "en") { _ in } }
        let pieceSent = await eventually { self.lines(ops).count == 2 }
        XCTAssertTrue(pieceSent, "Precondition: the helper has the file's first piece")

        file.cancel()
        try await Task.sleep(for: .milliseconds(300))
        let stillRunning = await client.isRunning
        XCTAssertTrue(stillRunning, "The helper keeps the model for the next dictation")
        try Data().write(to: go)

        do {
            _ = try await boundedValue(of: file)
            XCTFail("A cancelled transcription must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let next = try await client.transcribe(audioURL: audio, language: "en")
        XCTAssertEqual(next.text, "dictated")
        XCTAssertEqual(processIDs(launches).count, 1, "The same helper answers the next request")
        XCTAssertEqual(lines(ops), ["preload", "transcribePiece", "transcribe"], "No piece after the cancel")
    }

    /// The Mac going to sleep during a file: the helper must not end in the
    /// gap between two pieces, where no request runs or waits.
    func test_unloadModel_duringALongTranscription_waitsForItsLastPiece() async throws {
        let ops = directory.appendingPathComponent("ops")
        let launches = directory.appendingPathComponent("launches")
        let go = directory.appendingPathComponent("go")
        let client = makePieceClient(ops: ops, launches: launches, hold: "transcribePiece", go: go)
        let file = Task { try await client.transcribeLong(audioURL: try self.writeTwoUtterances(), language: "en") { _ in } }
        let pieceSent = await eventually { self.lines(ops).count == 2 }
        XCTAssertTrue(pieceSent, "Precondition: the helper has the file's first piece")

        await client.unloadModel()
        try Data().write(to: go)

        let result = try await boundedValue(of: file)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(processIDs(launches).count, 1, "Both pieces in the same helper")
        let stopped = await eventually { await client.isRunning == false }
        XCTAssertTrue(stopped, "The model is released once the file is done")
    }

    func test_convertedCopy_isDeleted_afterTheTranscription() async throws {
        let client = makePieceClient(
            ops: directory.appendingPathComponent("ops"), launches: directory.appendingPathComponent("launches"))
        let stereo = try writeTwoUtterances(sampleRate: 44_100, channels: 2)
        let before = convertedCopies()

        let result = try await client.transcribeLong(audioURL: stereo, language: "en") { _ in }

        XCTAssertEqual(result.segments.count, 2, "Precondition: the file was converted and cut")
        XCTAssertEqual(convertedCopies(), before, "The converted copy holds the user's audio")
    }

    func test_convertedCopy_isDeleted_afterACancel() async throws {
        let ops = directory.appendingPathComponent("ops")
        let go = directory.appendingPathComponent("go")
        let client = makePieceClient(
            ops: ops, launches: directory.appendingPathComponent("launches"), hold: "transcribePiece", go: go)
        let stereo = try writeTwoUtterances(sampleRate: 44_100, channels: 2)
        let before = convertedCopies()
        let file = Task { try await client.transcribeLong(audioURL: stereo, language: "en") { _ in } }
        let pieceSent = await eventually { self.lines(ops).count == 2 }
        XCTAssertTrue(pieceSent, "Precondition: the helper has the file's first piece")
        XCTAssertEqual(convertedCopies().subtracting(before).count, 1, "Precondition: the copy exists meanwhile")

        file.cancel()
        try Data().write(to: go)
        _ = try? await boundedValue(of: file)

        XCTAssertEqual(convertedCopies(), before)
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

    /// A helper that answers each request only once `go` exists, and notes
    /// in `received` that a request came.
    private func makeHeldClient(received: URL, go: URL) -> EngineProcessClient {
        makeClient(#"""
        while IFS= read -r line; do
          echo got >> "\#(received.path)"
          while [ ! -f "\#(go.path)" ]; do sleep 0.05; done
          printf '{"id":%s,"kind":"result","text":"done","language":"en","durationMs":1}\n' "$(id "$line")"
        done
        """#)
    }

    func test_unloadModel_duringARequest_letsItFinish_thenEndsTheHelper() async throws {
        let received = directory.appendingPathComponent("received")
        let go = directory.appendingPathComponent("go")
        let client = makeHeldClient(received: received, go: go)
        let request = Task { try await client.transcribe(audioURL: audio, language: "en") }
        let started = await eventually { FileManager.default.fileExists(atPath: received.path) }
        XCTAssertTrue(started)

        await client.unloadModel()
        let runningWhileBusy = await client.isRunning
        XCTAssertTrue(runningWhileBusy, "the Mac going to sleep must not end a transcription under way")
        try Data().write(to: go)

        let result = try await request.value
        XCTAssertEqual(result.text, "done")
        let stopped = await eventually { await client.isRunning == false }
        XCTAssertTrue(stopped, "the model is released once the request is done")
    }

    func test_killProcess_endsTheHelperAtOnce_andFailsTheRequest() async throws {
        let received = directory.appendingPathComponent("received")
        let client = makeHeldClient(received: received, go: directory.appendingPathComponent("never"))
        let request = Task { try await client.transcribe(audioURL: audio, language: "en") }
        let started = await eventually { FileManager.default.fileExists(atPath: received.path) }
        XCTAssertTrue(started)

        await client.killProcess()

        do {
            _ = try await request.value
            XCTFail("a request to a helper that was ended must fail")
        } catch {
            XCTAssertFalse(error is CancellationError, "\(error)")
        }
        let running = await client.isRunning
        XCTAssertFalse(running)
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

    // MARK: One request at a time

    /// A helper that answers each request only once `go` exists. At each
    /// start it notes its process id in `launches`; for each request it
    /// notes in `received` that a request came.
    private func makeHeldClient(
        received: URL,
        go: URL,
        launches: URL,
        idleSeconds: TimeInterval = 300,
        executable: URL = URL(fileURLWithPath: "/bin/sh")
    ) -> EngineProcessClient {
        makeClient(#"""
        echo $$ >> "\#(launches.path)"
        while IFS= read -r line; do
          echo got >> "\#(received.path)"
          while [ ! -f "\#(go.path)" ]; do sleep 0.05; done
          printf '{"id":%s,"kind":"result","text":"done","language":"en","durationMs":1}\n' "$(id "$line")"
        done
        """#, idleSeconds: idleSeconds, executable: executable)
    }

    private func lineCount(_ file: URL) -> Int {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private func processIDs(_ file: URL) -> [Int32] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) }
    }

    /// Starts request A, waits until the helper has it, then starts request B
    /// and waits until it is queued behind A.
    private func startRunningAndQueued(
        _ client: EngineProcessClient, received: URL
    ) async -> (running: Task<TranscriptionResult, Error>, queued: Task<TranscriptionResult, Error>) {
        let running = Task { try await client.transcribe(audioURL: audio, language: "en") }
        let sent = await eventually { self.lineCount(received) == 1 }
        XCTAssertTrue(sent, "Precondition: the helper has the first request")
        let queued = Task { try await client.transcribe(audioURL: audio, language: "en") }
        let waiting = await eventually { await client.queuedRequestCount == 1 }
        XCTAssertTrue(waiting, "Precondition: the second request waits in the client")
        return (running, queued)
    }

    func test_client_sendsOneRequestAtATime() async throws {
        // This helper reads its input at once, in the background, so that a
        // second request sent while the first is decoding would show. The
        // background reader needs `<&0`: without it, it would read /dev/null.
        let received = directory.appendingPathComponent("received")
        let go = directory.appendingPathComponent("go")
        let client = makeClient(#"""
        ( while IFS= read -r line; do printf '%s\n' "$line" >> "\#(received.path)"; done ) <&0 &
        answered=0
        while :; do
          count=0
          [ -f "\#(received.path)" ] && count=$(grep -c '' "\#(received.path)")
          if [ "$count" -gt "$answered" ]; then
            answered=$((answered + 1))
            line=$(sed -n "${answered}p" "\#(received.path)")
            while [ ! -f "\#(go.path)" ]; do sleep 0.05; done
            printf '{"id":%s,"kind":"result","text":"done","language":"en","durationMs":1}\n' "$(id "$line")"
          else
            sleep 0.02
          fi
        done
        """#)

        let first = Task { try await client.transcribe(audioURL: audio, language: "en") }
        let second = Task { try await client.transcribe(audioURL: audio, language: "en") }

        let sent = await eventually { self.lineCount(received) == 1 }
        XCTAssertTrue(sent)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(lineCount(received), 1, "the second request must wait until the first is done")
        try Data().write(to: go)

        let firstResult = try await boundedValue(of: first)
        let secondResult = try await boundedValue(of: second)
        XCTAssertEqual(firstResult.text, "done")
        XCTAssertEqual(secondResult.text, "done")
        XCTAssertEqual(lineCount(received), 2)
    }

    func test_cancellingAQueuedRequest_leavesTheHelperAlone() async throws {
        let received = directory.appendingPathComponent("received")
        let go = directory.appendingPathComponent("go")
        let launches = directory.appendingPathComponent("launches")
        let client = makeHeldClient(received: received, go: go, launches: launches)
        let (running, queued) = await startRunningAndQueued(client, received: received)
        let pid = try XCTUnwrap(processIDs(launches).first)

        queued.cancel()

        do {
            _ = try await boundedValue(of: queued)
            XCTFail("a cancelled request must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(kill(pid, 0), 0, "a request that was never sent must not end the helper")
        XCTAssertEqual(lineCount(received), 1)

        try Data().write(to: go)
        let result = try await boundedValue(of: running)
        XCTAssertEqual(result.text, "done")
        XCTAssertEqual(lineCount(received), 1, "the cancelled request must never be sent")
        let isRunning = await client.isRunning
        XCTAssertTrue(isRunning)
        XCTAssertEqual(processIDs(launches).count, 1)
    }

    func test_cancellingTheRunningRequest_endsThatHelper_andTheQueueContinuesInANewOne() async throws {
        let received = directory.appendingPathComponent("received")
        let go = directory.appendingPathComponent("go")
        let launches = directory.appendingPathComponent("launches")
        let client = makeHeldClient(received: received, go: go, launches: launches)
        let (running, queued) = await startRunningAndQueued(client, received: received)
        let firstPID = try XCTUnwrap(processIDs(launches).first)

        running.cancel()

        do {
            _ = try await boundedValue(of: running)
            XCTFail("a cancelled request must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let gone = await eventually { kill(firstPID, 0) != 0 }
        XCTAssertTrue(gone, "the helper must not keep decoding for a caller that left")
        let restarted = await eventually { self.processIDs(launches).count == 2 }
        XCTAssertTrue(restarted, "the waiting request must go to a new helper")

        try Data().write(to: go)
        let result = try await boundedValue(of: queued)
        XCTAssertEqual(result.text, "done")
    }

    func test_helperThatCrashes_failsOnlyTheRunningRequest_andTheQueueContinues() async throws {
        // The first helper process takes a request, then exits without a
        // reply once `go` exists; later ones answer.
        let received = directory.appendingPathComponent("received")
        let go = directory.appendingPathComponent("go")
        let launches = directory.appendingPathComponent("launches")
        let client = makeClient(#"""
        echo $$ >> "\#(launches.path)"
        if [ "$(grep -c '' "\#(launches.path)")" -eq 1 ]; then
          read -r line
          echo got >> "\#(received.path)"
          while [ ! -f "\#(go.path)" ]; do sleep 0.05; done
          exit 3
        fi
        while IFS= read -r line; do
          printf '{"id":%s,"kind":"result","text":"second process","language":"en","durationMs":1}\n' "$(id "$line")"
        done
        """#)
        let (running, queued) = await startRunningAndQueued(client, received: received)

        try Data().write(to: go)

        do {
            _ = try await boundedValue(of: running)
            XCTFail("the request to a helper that exits must fail")
        } catch MurmurError.transcriptionFailed(let message) {
            XCTAssertTrue(message.contains("stopped unexpectedly"), message)
        } catch {
            XCTFail("expected transcriptionFailed, got \(error)")
        }
        let result = try await boundedValue(of: queued)
        XCTAssertEqual(result.text, "second process")
        XCTAssertEqual(processIDs(launches).count, 2)
    }

    /// The helper survives `unloadModel` while one request runs and one
    /// waits, and ends after both. The client never holds a waiting request
    /// with none running, so this cannot tell a busy check that looks only
    /// at the running request from one that also looks at the queue.
    func test_unloadModel_withARunningAndAQueuedRequest_letsBothFinish_thenEndsTheHelper() async throws {
        let received = directory.appendingPathComponent("received")
        let go = directory.appendingPathComponent("go")
        let launches = directory.appendingPathComponent("launches")
        let client = makeHeldClient(received: received, go: go, launches: launches)
        let (running, queued) = await startRunningAndQueued(client, received: received)

        await client.unloadModel()
        let runningWhileBusy = await client.isRunning
        XCTAssertTrue(runningWhileBusy, "the Mac going to sleep must not end the requests under way")
        try Data().write(to: go)

        let first = try await boundedValue(of: running)
        let second = try await boundedValue(of: queued)
        XCTAssertEqual(first.text, "done")
        XCTAssertEqual(second.text, "done")
        let stopped = await eventually { await client.isRunning == false }
        XCTAssertTrue(stopped, "the model is released once the requests are done")
        XCTAssertEqual(processIDs(launches).count, 1)
    }

    func test_killProcess_failsTheRunningAndTheQueuedRequest() async throws {
        let received = directory.appendingPathComponent("received")
        let launches = directory.appendingPathComponent("launches")
        let client = makeHeldClient(
            received: received, go: directory.appendingPathComponent("never"), launches: launches
        )
        let (running, queued) = await startRunningAndQueued(client, received: received)

        await client.killProcess()

        for request in [running, queued] {
            do {
                _ = try await boundedValue(of: request)
                XCTFail("a request to a helper that was ended must fail")
            } catch {
                XCTAssertFalse(error is CancellationError, "\(error)")
            }
        }
        let isRunning = await client.isRunning
        XCTAssertFalse(isRunning)
        XCTAssertEqual(processIDs(launches).count, 1, "the waiting request must not start a new helper")
    }

    /// The idle countdown runs out while one request runs and one waits, and
    /// the helper survives it. As with `unloadModel`, the client never holds
    /// a waiting request with none running, so this proves the busy check,
    /// not which half of it held.
    func test_idleStop_doesNotFire_whileARequestIsQueued() async throws {
        let received = directory.appendingPathComponent("received")
        let go = directory.appendingPathComponent("go")
        let launches = directory.appendingPathComponent("launches")
        let client = makeHeldClient(received: received, go: go, launches: launches, idleSeconds: 0.5)
        // One finished request starts the idle countdown.
        try Data().write(to: go)
        _ = try await client.transcribe(audioURL: audio, language: "en")
        try FileManager.default.removeItem(at: go)
        try FileManager.default.removeItem(at: received)
        let (running, queued) = await startRunningAndQueued(client, received: received)

        try await Task.sleep(for: .milliseconds(800))

        let runningWhileBusy = await client.isRunning
        XCTAssertTrue(runningWhileBusy, "the idle time must not end a helper with requests to do")
        XCTAssertEqual(
            processIDs(launches).count, 1,
            "the countdown ran out while the helper had the requests, and must have left it alone"
        )
        try Data().write(to: go)
        _ = try await boundedValue(of: running)
        _ = try await boundedValue(of: queued)
        let stopped = await eventually { await client.isRunning == false }
        XCTAssertTrue(stopped, "the helper must not outlive the idle time once the requests are done")
    }

    func test_requestCancelledBeforeItWasSent_isNeverSent() async throws {
        let log = directory.appendingPathComponent("requests.log")
        let client = makeClient(#"""
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "\#(log.path)"
          printf '{"id":%s,"kind":"result","text":"x","language":"en","durationMs":1}\n' "$(id "$line")"
        done
        """#)
        let request = Task {
            // Asks only once it has been cancelled.
            while !Task.isCancelled { await Task.yield() }
            return try await client.transcribe(audioURL: audio, language: "en")
        }

        request.cancel()

        do {
            _ = try await boundedValue(of: request)
            XCTFail("a cancelled request must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        // Requests are numbered from 1. One that was sent, even to a helper
        // that was then ended, took a number, so the next one would be 2.
        let next = Task { try await client.transcribe(audioURL: audio, language: "en") }
        _ = try await boundedValue(of: next)
        let sent = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .map { try EngineWire.decode(EngineRequest.self, from: String($0)) }
        XCTAssertEqual(sent.map(\.id), [1], "a cancelled request must not reach the helper")
    }

    /// The helper exits right after a reply, before the client sends the
    /// next request: the write fails. That is a crash like any other, so
    /// only the request that could not be sent fails.
    func test_helperThatExitsRightAfterAReply_failsOnlyTheNextRequest_andTheQueueContinues() async throws {
        let received = directory.appendingPathComponent("received")
        let go = directory.appendingPathComponent("go")
        let launches = directory.appendingPathComponent("launches")
        // The first helper closes its input before it replies, so the write
        // of the next request fails for certain, and keeps its output open,
        // so the client does not see it end first.
        let client = makeClient(#"""
        echo $$ >> "\#(launches.path)"
        if [ "$(grep -c '' "\#(launches.path)")" -eq 1 ]; then
          read -r line
          echo got >> "\#(received.path)"
          while [ ! -f "\#(go.path)" ]; do sleep 0.05; done
          exec 0<&-
          printf '{"id":%s,"kind":"result","text":"done","language":"en","durationMs":1}\n' "$(id "$line")"
          exec sleep 30
        fi
        while IFS= read -r line; do
          printf '{"id":%s,"kind":"result","text":"second process","language":"en","durationMs":1}\n' "$(id "$line")"
        done
        """#)
        let (running, queued) = await startRunningAndQueued(client, received: received)
        let last = Task { try await client.transcribe(audioURL: audio, language: "en") }
        let waiting = await eventually { await client.queuedRequestCount == 2 }
        XCTAssertTrue(waiting, "Precondition: two requests wait in the client")

        try Data().write(to: go)

        let first = try await boundedValue(of: running)
        XCTAssertEqual(first.text, "done")
        do {
            _ = try await boundedValue(of: queued)
            XCTFail("a request that could not be sent must fail")
        } catch MurmurError.transcriptionFailed(let message) {
            XCTAssertTrue(message.contains("could not be reached"), message)
        } catch {
            XCTFail("expected transcriptionFailed, got \(error)")
        }
        let result = try await boundedValue(of: last)
        XCTAssertEqual(result.text, "second process", "the waiting request must go to a new helper")
        XCTAssertEqual(processIDs(launches).count, 2)
    }

    /// An `unloadModel` came while requests were under way, and the restart
    /// after a cancel could not start a helper. The unload is done once no
    /// helper runs; it must not end the next helper after its first reply.
    func test_unloadModel_whoseRestartFailed_doesNotEndTheNextHelper() async throws {
        let received = directory.appendingPathComponent("received")
        let go = directory.appendingPathComponent("go")
        let launches = directory.appendingPathComponent("launches")
        // The helper is started through a link that the test takes away.
        let link = directory.appendingPathComponent("engine")
        let shell = URL(fileURLWithPath: "/bin/sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shell)
        let client = makeHeldClient(received: received, go: go, launches: launches, executable: link)
        let (running, queued) = await startRunningAndQueued(client, received: received)
        await client.unloadModel()
        try FileManager.default.removeItem(at: link)

        running.cancel()

        do {
            _ = try await boundedValue(of: running)
            XCTFail("a cancelled request must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        do {
            _ = try await boundedValue(of: queued)
            XCTFail("a request with no helper to run it must fail")
        } catch {
            XCTAssertFalse(error is CancellationError, "\(error)")
        }
        let stopped = await client.isRunning
        XCTAssertFalse(stopped, "Precondition: no helper could be started")

        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shell)
        try Data().write(to: go)
        let later = Task { try await client.transcribe(audioURL: audio, language: "en") }
        let result = try await boundedValue(of: later)
        XCTAssertEqual(result.text, "done")
        let isRunning = await client.isRunning
        XCTAssertTrue(isRunning, "the helper must stay for the next request, as after any other")
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

/// The value of `task`, or a test failure after 5 s. A request that the
/// client never resumes would otherwise hang the whole suite instead of
/// failing the one test.
private func boundedValue<T>(
    of task: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line
) async throws -> T {
    guard let outcome = await outcome(of: task, within: 5) else {
        XCTFail("the request did not finish within 5 s", file: file, line: line)
        throw RequestDidNotFinish()
    }
    return try outcome.get()
}

private struct RequestDidNotFinish: Error {}

/// `task`'s outcome, or nil when it has none after `seconds`. Not a task
/// group: a group waits for all of its tasks, and the one that waits for
/// `task` would never end.
private func outcome<T>(of task: Task<T, Error>, within seconds: TimeInterval) async -> Result<T, Error>? {
    let once = Once()
    return await withCheckedContinuation { continuation in
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if once.claim() { continuation.resume(returning: nil) }
        }
        Task {
            let result = await task.result
            if once.claim() {
                timer.cancel()
                continuation.resume(returning: result)
            }
        }
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
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

    func test_pieceRequest_carriesItsRangeAsAPair() throws {
        var request = EngineRequest(id: 3, operation: .transcribePiece)
        request.range = 16_000..<48_000
        let line = String(decoding: try EngineWire.line(request), as: UTF8.self)

        XCTAssertTrue(line.contains(#""range":[16000,48000]"#), line)
        XCTAssertEqual(try EngineWire.decode(EngineRequest.self, from: line).range, 16_000..<48_000)
    }

    func test_transcribePiece_repliesWithThePiecesText() async throws {
        let service = SpyTranscriptionService()
        var request = EngineRequest(id: 9, operation: .transcribePiece)
        request.path = "/tmp/a.wav"
        request.range = 32_000..<64_000

        let replies = try await serve(service, [request])

        XCTAssertEqual(replies, [.pieceText(id: 9, "piece 32000")])
        XCTAssertEqual(service.piecesAsked, [32_000..<64_000])
    }

    func test_pieceWithoutARange_isAFailure() async throws {
        var request = EngineRequest(id: 5, operation: .transcribePiece)
        request.path = "/tmp/a.wav"
        let replies = try await serve(SpyTranscriptionService(), [request])
        XCTAssertEqual(replies.map(\.kind), [.failure])
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
