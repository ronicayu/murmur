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

    // MARK: - disk budget

    func test_diskBudgetBytes_is_2GB() {
        XCTAssertEqual(LongRecordingService.diskBudgetBytes, 2 * 1024 * 1024 * 1024,
                       "Disk budget must be 2 GB")
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
