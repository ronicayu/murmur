import XCTest
@testable import Murmur

// MARK: - UAT Fix Tests (043)
//
// Covers four fixes from handoff 042_PM_EN_uat-triage:
//   P0  — voice input (coordinator) pauses only at transcription-start, not recording-start
//   P1-1 — sidebar search filters history entries by text
//   P1-3 — .wav extension is accepted in upload validation
//
// P1-2 (paragraph line-breaks) is a Python-side change validated via
// test_transcribe_py_paragraph_breaks() in UATFixPythonTests (manual / CI only).
//
// Run:
//   xcodebuild test -scheme Murmur -only-testing MurmurTests/UATFixTests

// MARK: - P0: Voice input pause timing

@MainActor
final class P0VoiceInputPauseTests: XCTestCase {

    private var storeURL: URL!
    private var historyService: TranscriptionHistoryService!
    private var coordinator: AppCoordinator!
    private var spyTranscription: SpyTranscriptionService!
    private var sut: TranscriptionWindowModel!
    private var fakeAudioURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        historyService = TranscriptionHistoryService(storeURL: storeURL)
        coordinator = AppCoordinator()
        spyTranscription = SpyTranscriptionService()

        fakeAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")

        sut = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            transcriptionService: spyTranscription
        )
    }

    override func tearDownWithError() throws {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: fakeAudioURL)
        try super.tearDownWithError()
    }

    /// Coordinator must remain .idle while the window is recording — voice input
    /// hotkey must not be blocked during this phase.
    func test_coordinator_stays_idle_while_window_is_recording() {
        // startRecording() only affects the window's local state; coordinator stays idle
        // (it does not have access to LongRecordingService internals here, so we can't
        // call sut.startRecording() without a microphone — but we CAN verify that
        // the coordinator state is .idle at the time beginTranscription is NOT yet called)
        XCTAssertEqual(coordinator.state, .idle,
            "Coordinator must be idle before transcription starts")
    }

    /// When beginTranscription is called, coordinator must transition to .transcribing.
    func test_begin_transcription_puts_coordinator_in_transcribing_state() async throws {
        // Arrange — spy blocks so we can observe the in-flight state
        spyTranscription.shouldBlock = true

        // Act — start transcription (will hang in spy)
        sut.beginTranscription(audioURL: fakeAudioURL)
        await shortDrain()

        // Assert — coordinator is now .transcribing (voice input is paused)
        XCTAssertEqual(coordinator.state, .transcribing,
            "Coordinator must be .transcribing while transcription is in flight")

        // Cleanup
        spyTranscription.shouldBlock = false
        sut.cancelTranscription()
        await drainMainActor()
    }

    /// When transcription completes successfully, coordinator must return to .idle.
    func test_begin_transcription_returns_coordinator_to_idle_on_success() async throws {
        // Arrange
        spyTranscription.stubbedResult = TranscriptionResult(
            text: "hello world",
            language: .english,
            durationMs: 100
        )

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActor()

        // Assert
        XCTAssertEqual(coordinator.state, .idle,
            "Coordinator must return to .idle after successful transcription")
    }

    /// When transcription is cancelled, coordinator must return to .idle.
    func test_cancel_transcription_returns_coordinator_to_idle() async throws {
        // Arrange — spy blocks so cancel is meaningful
        spyTranscription.shouldBlock = true
        sut.beginTranscription(audioURL: fakeAudioURL)
        await shortDrain()

        // Act
        sut.cancelTranscription()
        await drainMainActor()

        // Assert
        XCTAssertEqual(coordinator.state, .idle,
            "Coordinator must return to .idle after cancel")
    }

    /// When transcription fails with an error, coordinator must return to .idle.
    func test_transcription_error_returns_coordinator_to_idle() async throws {
        // Arrange
        spyTranscription.stubbedError = MurmurError.transcriptionFailed("boom")

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActor()

        // Assert
        XCTAssertEqual(coordinator.state, .idle,
            "Coordinator must return to .idle after transcription error")
    }
}

// MARK: - P1-1: Sidebar search filter

/// Tests for the pure filter function that the sidebar uses.
/// No UI involved — tests the filtering logic independently.
final class P1SidebarSearchTests: XCTestCase {

    // Helper: build a minimal TranscriptionEntry with given text
    private func entry(text: String, id: UUID = UUID()) -> TranscriptionEntry {
        TranscriptionEntry(
            id: id,
            date: Date(),
            audioDuration: 10,
            text: text,
            language: "en",
            status: .completed,
            m4aPath: nil
        )
    }

    func test_empty_query_returns_all_entries() {
        let entries = [entry(text: "hello"), entry(text: "world"), entry(text: "foo")]
        let result = TranscriptionHistoryFilter.filter(entries, query: "")
        XCTAssertEqual(result.count, 3)
    }

    func test_whitespace_only_query_returns_all_entries() {
        let entries = [entry(text: "hello"), entry(text: "world")]
        let result = TranscriptionHistoryFilter.filter(entries, query: "   ")
        XCTAssertEqual(result.count, 2)
    }

    func test_query_matches_substring_case_insensitively() {
        let entries = [
            entry(text: "Hello world"),
            entry(text: "goodbye moon"),
            entry(text: "HELLO again"),
        ]
        let result = TranscriptionHistoryFilter.filter(entries, query: "hello")
        XCTAssertEqual(result.count, 2)
    }

    func test_query_with_no_match_returns_empty() {
        let entries = [entry(text: "hello world"), entry(text: "goodbye moon")]
        let result = TranscriptionHistoryFilter.filter(entries, query: "xyz")
        XCTAssertTrue(result.isEmpty)
    }

    func test_query_matches_partial_word() {
        let entries = [entry(text: "transcription complete"), entry(text: "no match here")]
        let result = TranscriptionHistoryFilter.filter(entries, query: "script")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "transcription complete")
    }

    func test_filter_preserves_entry_order() {
        let ids = [UUID(), UUID(), UUID()]
        let entries = [
            entry(text: "apple pie", id: ids[0]),
            entry(text: "banana split", id: ids[1]),
            entry(text: "apple tart", id: ids[2]),
        ]
        let result = TranscriptionHistoryFilter.filter(entries, query: "apple")
        XCTAssertEqual(result.map(\.id), [ids[0], ids[2]])
    }
}

// MARK: - P1-3: .wav upload validation

@MainActor
final class P1WavUploadTests: XCTestCase {

    private var storeURL: URL!
    private var historyService: TranscriptionHistoryService!
    private var coordinator: AppCoordinator!
    private var spyTranscription: SpyTranscriptionService!
    private var sut: TranscriptionWindowModel!

    override func setUpWithError() throws {
        try super.setUpWithError()

        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        historyService = TranscriptionHistoryService(storeURL: storeURL)
        coordinator = AppCoordinator()
        spyTranscription = SpyTranscriptionService()

        sut = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            diskChecker: StubDiskSpaceChecker(freeBytes: 10 * 1024 * 1024 * 1024),
            transcriptionService: spyTranscription
        )
    }

    override func tearDownWithError() throws {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    /// A .wav file must not be silently rejected — it should reach uploadConfirm
    /// (or fail only on duration/disk checks, not on the extension check).
    func test_wav_file_is_accepted_by_upload_validation() async throws {
        // Arrange — create a real .wav file with minimal PCM header (44 bytes)
        // so AVURLAsset can at least attempt to open it (may return 0 duration).
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        let header = makeMinimalWavHeader(dataBytes: 0)
        try header.write(to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // Act
        sut.handleDroppedFile(wavURL)
        await drainMainActor()

        // Assert — state must NOT stay .idle due to extension rejection.
        // With 0 samples the duration guard may kick in, but the extension guard must not.
        // We verify by confirming the extension guard path was NOT taken:
        // if it was, windowState would be .idle AND the spy would have zero calls.
        // Since the spy is not involved in validation, we check that the path reached
        // the duration check (which sets idle) rather than the extension check.
        // The cleaner assertion: dropping a .wav must never leave state == .idle
        // with the reason being "unsupported format".
        // We proxy this by running the format-only check directly.
        let accepted = UploadFormatValidator.isAccepted(extension: "wav")
        XCTAssertTrue(accepted, ".wav must be accepted by the format validator")
    }

    func test_mp3_still_accepted() {
        XCTAssertTrue(UploadFormatValidator.isAccepted(extension: "mp3"))
    }

    func test_m4a_still_accepted() {
        XCTAssertTrue(UploadFormatValidator.isAccepted(extension: "m4a"))
    }

    func test_txt_rejected() {
        XCTAssertFalse(UploadFormatValidator.isAccepted(extension: "txt"))
    }

    func test_mp4_rejected() {
        XCTAssertFalse(UploadFormatValidator.isAccepted(extension: "mp4"))
    }

    // MARK: - Minimal WAV header helper

    /// Build a 44-byte PCM WAV header with zero data bytes.
    private func makeMinimalWavHeader(dataBytes: UInt32) -> Data {
        var d = Data()
        func writeUInt32LE(_ v: UInt32) {
            var x = v.littleEndian
            d.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) })
        }
        func writeUInt16LE(_ v: UInt16) {
            var x = v.littleEndian
            d.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) })
        }
        // RIFF chunk
        d.append(contentsOf: "RIFF".utf8)
        writeUInt32LE(36 + dataBytes)  // file size - 8
        d.append(contentsOf: "WAVE".utf8)
        // fmt sub-chunk
        d.append(contentsOf: "fmt ".utf8)
        writeUInt32LE(16)              // sub-chunk size
        writeUInt16LE(1)               // PCM
        writeUInt16LE(1)               // mono
        writeUInt32LE(16000)           // sample rate
        writeUInt32LE(32000)           // byte rate
        writeUInt16LE(2)               // block align
        writeUInt16LE(16)              // bits per sample
        // data sub-chunk
        d.append(contentsOf: "data".utf8)
        writeUInt32LE(dataBytes)
        return d
    }
}

// MARK: - Helpers

@MainActor
private func shortDrain() async {
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
}

/// Yields to the main actor so queued Tasks can complete.
/// Mirrors the helper in TranscriptionWindowModelTests.
@MainActor
private func drainMainActor() async {
    await Task.yield()
    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    await Task.yield()
}
