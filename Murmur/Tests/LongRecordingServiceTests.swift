import XCTest
import AVFoundation
@testable import Murmur

// MARK: - LongRecordingService Tests
//
// @MainActor because LongRecordingService is MainActor-isolated.

@MainActor
final class LongRecordingServiceTests: XCTestCase {

    private var tempDir: URL!
    private var sut: LongRecordingService!
    private var mockDiskCheck: MockDiskSpaceChecker!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDiskCheck = MockDiskSpaceChecker()
        sut = LongRecordingService(outputDirectory: tempDir, diskChecker: mockDiskCheck)
    }

    override func tearDownWithError() throws {
        try? sut.cancel()
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Disk space validation

    func test_start_throws_when_disk_space_below_1GB() async throws {
        // Arrange — simulate 500 MB free
        mockDiskCheck.freeBytes = 500 * 1024 * 1024

        // Act & Assert
        do {
            try await sut.startRecording()
            XCTFail("Expected insufficientDiskSpace error")
        } catch LongRecordingError.insufficientDiskSpace {
            // pass
        }
    }

    func test_start_succeeds_when_disk_space_above_1GB() async throws {
        // Arrange — 2 GB free
        mockDiskCheck.freeBytes = 2 * 1024 * 1024 * 1024

        // Act & Assert — no throw (we immediately cancel to avoid real recording)
        // This is an integration-light test; AVAudioRecorder requires mic permission in CI
        // so we stub the recorder factory.
        let recorder = MockAVRecorderBridge()
        sut = LongRecordingService(
            outputDirectory: tempDir,
            diskChecker: mockDiskCheck,
            recorderFactory: { url, settings in recorder }
        )
        try await sut.startRecording()
        XCTAssertTrue(recorder.didStart)
    }

    // MARK: - Output file

    func test_start_produces_m4a_output_path() async throws {
        // Arrange
        mockDiskCheck.freeBytes = 2 * 1024 * 1024 * 1024
        let recorder = MockAVRecorderBridge()
        sut = LongRecordingService(
            outputDirectory: tempDir,
            diskChecker: mockDiskCheck,
            recorderFactory: { url, settings in recorder }
        )

        // Act
        try await sut.startRecording()

        // Assert — the current output URL exists and has .m4a extension
        let outputURL = sut.currentOutputURL
        XCTAssertNotNil(outputURL)
        XCTAssertEqual(outputURL?.pathExtension, "m4a")
    }

    // MARK: - stop

    func test_stop_returns_m4a_url() async throws {
        // Arrange
        mockDiskCheck.freeBytes = 2 * 1024 * 1024 * 1024
        let recorder = MockAVRecorderBridge()
        sut = LongRecordingService(
            outputDirectory: tempDir,
            diskChecker: mockDiskCheck,
            recorderFactory: { url, settings in recorder }
        )
        try await sut.startRecording()

        // Act
        let url = try await sut.stopRecording()

        // Assert
        XCTAssertEqual(url.pathExtension, "m4a")
        XCTAssertTrue(recorder.didStop)
    }

    func test_stop_without_start_throws() async {
        // Act & Assert
        do {
            _ = try await sut.stopRecording()
            XCTFail("Expected notRecording error")
        } catch LongRecordingError.notRecording {
            // pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - cancel

    func test_cancel_without_start_does_not_throw() throws {
        XCTAssertNoThrow(try sut.cancel())
    }

    func test_cancel_deletes_in_progress_m4a() async throws {
        // Arrange
        mockDiskCheck.freeBytes = 2 * 1024 * 1024 * 1024
        let recorder = MockAVRecorderBridge()
        var capturedURL: URL?
        sut = LongRecordingService(
            outputDirectory: tempDir,
            diskChecker: mockDiskCheck,
            recorderFactory: { url, settings in
                capturedURL = url
                // Create a real stub file so we can verify deletion
                FileManager.default.createFile(atPath: url.path, contents: Data("stub".utf8))
                return recorder
            }
        )
        try await sut.startRecording()

        // Act
        try sut.cancel()

        // Assert — stub file deleted
        if let url = capturedURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertTrue(recorder.didStop)
    }

    // MARK: - duration cap

    func test_maxDurationSeconds_is_7200() {
        XCTAssertEqual(LongRecordingService.maxDurationSeconds, 7200,
                       "2-hour cap must be 7200 seconds")
    }

    // MARK: - auto-stop at the duration cap

    /// Builds a service whose duration cap is reached when the returned stream
    /// is finished, instead of after two real hours.
    private func makeServiceWithManualCap(
        recorder: MockAVRecorderBridge
    ) -> (service: LongRecordingService, reachCap: () -> Void) {
        mockDiskCheck.freeBytes = 2 * 1024 * 1024 * 1024
        let (capReached, continuation) = AsyncStream<Void>.makeStream()
        let service = LongRecordingService(
            outputDirectory: tempDir,
            diskChecker: mockDiskCheck,
            recorderFactory: { url, settings in recorder },
            autoStopSleep: { _ in for await _ in capReached {} }
        )
        return (service, { continuation.finish() })
    }

    func test_autoStop_stops_recorder_and_reports_the_m4a() async throws {
        // Arrange
        let recorder = MockAVRecorderBridge()
        let (service, reachCap) = makeServiceWithManualCap(recorder: recorder)
        sut = service
        let reported = expectation(description: "onAutoStop called")
        var reportedURL: URL?
        sut.onAutoStop = { url in
            reportedURL = url
            reported.fulfill()
        }
        try await sut.startRecording()
        let outputURL = try XCTUnwrap(sut.currentOutputURL)

        // Act
        reachCap()
        await fulfillment(of: [reported], timeout: 5)

        // Assert
        XCTAssertEqual(reportedURL, outputURL)
        XCTAssertTrue(recorder.didStop)
        do {
            _ = try await sut.stopRecording()
            XCTFail("Expected notRecording — the auto-stop already ended the recording")
        } catch LongRecordingError.notRecording {
            // pass
        }
    }

    func test_manual_stop_does_not_report_autoStop() async throws {
        // Arrange
        let recorder = MockAVRecorderBridge()
        let (service, reachCap) = makeServiceWithManualCap(recorder: recorder)
        sut = service
        var autoStopCount = 0
        sut.onAutoStop = { _ in autoStopCount += 1 }
        try await sut.startRecording()

        // Act — the owner stops first; the cap is reached afterwards
        _ = try await sut.stopRecording()
        reachCap()
        for _ in 0..<50 { await Task.yield() }

        // Assert
        XCTAssertEqual(autoStopCount, 0, "onAutoStop is only for the duration cap")
    }

    // MARK: - file ownership

    func test_ownsRecording_true_for_its_own_output_file() async throws {
        // Arrange
        mockDiskCheck.freeBytes = 2 * 1024 * 1024 * 1024
        sut = LongRecordingService(
            outputDirectory: tempDir,
            diskChecker: mockDiskCheck,
            recorderFactory: { url, settings in MockAVRecorderBridge() }
        )
        try await sut.startRecording()
        let outputURL = try XCTUnwrap(sut.currentOutputURL)

        // Assert
        XCTAssertTrue(sut.ownsRecording(at: outputURL))
    }

    func test_ownsRecording_false_for_files_outside_the_output_directory() throws {
        // Arrange — a "user" directory next to the recordings directory
        let userDir = tempDir.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: userDir) }
        let userFile = userDir.appendingPathComponent("song.m4a")
        FileManager.default.createFile(atPath: userFile.path, contents: Data("user".utf8))

        // A path that starts inside the output directory but leaves it
        let escaping = tempDir
            .appendingPathComponent("..")
            .appendingPathComponent(userDir.lastPathComponent)
            .appendingPathComponent("song.m4a")
        // A symlink inside the output directory that points at the user's file
        let link = tempDir.appendingPathComponent("link.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: userFile)

        // Assert
        XCTAssertFalse(sut.ownsRecording(at: userFile))
        XCTAssertFalse(sut.ownsRecording(at: escaping))
        XCTAssertFalse(sut.ownsRecording(at: link))
        XCTAssertFalse(sut.ownsRecording(at: tempDir), "The directory itself is not a recording")
        XCTAssertFalse(sut.ownsRecording(at: tempDir.appendingPathComponent("sub/a.m4a")))
        XCTAssertTrue(sut.ownsRecording(at: tempDir.appendingPathComponent("a.m4a")))
    }
}

// MARK: - Test doubles

final class MockDiskSpaceChecker: DiskSpaceChecking {
    var freeBytes: Int64 = 0

    func availableCapacityBytes() throws -> Int64 {
        return freeBytes
    }
}

final class MockAVRecorderBridge: AVRecorderBridging {
    var didStart = false
    var didStop = false

    func prepareToRecord() -> Bool { true }
    func record() -> Bool {
        didStart = true
        return true
    }
    func stop() {
        didStop = true
    }
}
