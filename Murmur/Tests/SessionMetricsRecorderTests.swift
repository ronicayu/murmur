import XCTest
@testable import Murmur

// Phase 5 of the 10x plan: local-only measurement loop. These tests run against
// a temp-directory file — no Application Support writes, no models, light tier.

final class SessionMetricsRecorderTests: XCTestCase {

    private var fileURL: URL!
    private var recorder: SessionMetricsRecorder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("session-metrics.jsonl")
        recorder = SessionMetricsRecorder(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        recorder = nil
        fileURL = nil
        try super.tearDownWithError()
    }

    private func sample(
        mode: SessionMetrics.Mode = .v3Streaming,
        outcome: SessionMetrics.Outcome = .injected,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SessionMetrics {
        SessionMetrics(
            date: date,
            mode: mode,
            outcome: outcome,
            language: "en",
            audioDurationMs: 10_000,
            stopToFinalTextMs: 650,
            timeToFirstWordMs: 900,
            finalizeLatencyMs: 620,
            editDistanceRatio: 0.004,
            cpuFallback: false,
            chunkCount: 4
        )
    }

    // MARK: - Round-trip

    func test_record_thenRecent_roundTripsAllFields() {
        let m = sample()
        recorder.record(m)

        let back = recorder.recent()
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first, m,
            "Every metric field must survive the JSON round-trip")
    }

    func test_createsFileAndParentDirectory_onFirstRecord() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        recorder.record(sample())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
            "The recorder must create its parent directory, not silently no-op")
    }

    func test_recent_isEmpty_whenNothingRecorded() {
        XCTAssertTrue(recorder.recent().isEmpty)
    }

    // MARK: - JSON-lines shape

    func test_eachRecordIsOneLine() throws {
        recorder.record(sample())
        recorder.record(sample())
        recorder.record(sample())

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3, "One JSON object per line")
        for line in lines {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                "Every line must independently parse as JSON")
        }
    }

    func test_appendsRatherThanOverwrites() {
        recorder.record(sample(mode: .v1FullPass))
        recorder.record(sample(mode: .v3Streaming))
        let back = recorder.recent()
        XCTAssertEqual(back.map(\.mode), [.v1FullPass, .v3Streaming],
            "Records must accumulate in order, not replace each other")
    }

    func test_survivesRecorderReinstantiation() {
        recorder.record(sample())
        // Simulates an app relaunch against the same file.
        let reopened = SessionMetricsRecorder(fileURL: fileURL)
        XCTAssertEqual(reopened.recent().count, 1)
    }

    // MARK: - Robustness

    func test_malformedLineIsSkipped_notFatal() throws {
        recorder.record(sample())
        // Simulate a torn write from a crash mid-append.
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"partial\":\n".utf8))
        try handle.close()
        recorder.record(sample())

        let back = recorder.recent()
        XCTAssertEqual(back.count, 2,
            "A corrupt line must cost only itself — surrounding history stays readable")
    }

    func test_reset_clearsHistory() {
        recorder.record(sample())
        recorder.reset()
        XCTAssertTrue(recorder.recent().isEmpty)
    }

    // MARK: - Capping

    func test_fileIsCapped_afterExceedingMaxPlusSlack() {
        let capped = SessionMetricsRecorder(fileURL: fileURL, maxRecords: 10, compactionSlack: 5)
        for i in 0..<40 {
            capped.record(sample(date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i))))
        }
        let back = capped.recent(limit: 1000)
        XCTAssertLessThanOrEqual(back.count, 16,
            "The file must not grow without bound")
        XCTAssertGreaterThanOrEqual(back.count, 10,
            "Compaction must retain at least maxRecords")
    }

    func test_compaction_keepsNewestRecords() {
        let capped = SessionMetricsRecorder(fileURL: fileURL, maxRecords: 5, compactionSlack: 0)
        for i in 0..<30 {
            capped.record(sample(date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i))))
        }
        let back = capped.recent(limit: 1000)
        let newest = back.last?.date.timeIntervalSince1970
        XCTAssertEqual(newest, 1_700_000_029,
            "Compaction must drop the OLDEST records, keeping the newest")
    }

    func test_recent_limitReturnsTail() {
        for i in 0..<10 {
            recorder.record(sample(date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i))))
        }
        let back = recorder.recent(limit: 3)
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back.last?.date.timeIntervalSince1970, 1_700_000_009,
            "recent(limit:) returns the newest N")
    }

    // MARK: - Mode-dependent fields

    func test_v1Session_omitsStreamingOnlyFields() throws {
        let v1 = SessionMetrics(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            mode: .v1FullPass,
            outcome: .injected,
            language: "zh",
            audioDurationMs: 3_000,
            stopToFinalTextMs: 1_800
        )
        recorder.record(v1)
        let back = try XCTUnwrap(recorder.recent().first)
        XCTAssertNil(back.timeToFirstWordMs,
            "A full-pass session streams nothing, so time-to-first-word is absent")
        XCTAssertNil(back.editDistanceRatio)
        XCTAssertEqual(back.stopToFinalTextMs, 1_800)
    }

    func test_silenceGatedSession_isRecorded() {
        // Gate outcomes matter: a silently-dropped utterance is the exact class
        // of bug the 0.4.x releases kept shipping.
        let gated = SessionMetrics(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            mode: .v1FullPass,
            outcome: .silenceGated,
            language: "en",
            audioDurationMs: 400
        )
        recorder.record(gated)
        XCTAssertEqual(recorder.recent().first?.outcome, .silenceGated)
    }

    func test_cpuFallbackFlag_persists() {
        var m = sample()
        m.cpuFallback = true
        recorder.record(m)
        XCTAssertEqual(recorder.recent().first?.cpuFallback, true)
    }

    // MARK: - Concurrency

    func test_concurrentRecords_doNotCorruptFile() {
        let group = DispatchGroup()
        for i in 0..<50 {
            DispatchQueue.global().async(group: group) { [recorder] in
                recorder?.record(
                    self.sample(date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i)))
                )
            }
        }
        group.wait()

        let back = recorder.recent(limit: 1000)
        XCTAssertEqual(back.count, 50,
            "Every concurrent append must land as its own well-formed line")
    }
}
