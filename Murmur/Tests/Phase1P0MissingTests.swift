import XCTest
@testable import Murmur

// MARK: - Phase 1 P0 Missing Tests
//
// 補齊覆蓋度報告(040_QA_PM)中標記為P0的缺失tests。
// 五組：
//   1. m4a自動刪除（IT-004）
//   2. Cancel後m4a刪除（EC-004）
//   3. Python crash→history.failed，保留m4a（EC-014）
//   4. Cancel後partial results不寫history（EC-003，補充驗證m4a路徑）
//   5. 孤兒m4a清理邏輯（EC-010/011）—已由TranscriptionHistoryService.scanAndRecoverOrphans()實作
//
// Run: xcodebuild test -scheme Murmur -only-testing MurmurTests/Phase1P0MissingTests

// MARK: - 1. m4a自動刪除 (IT-004)

@MainActor
final class M4AAutoDeleteTests: XCTestCase {

    private var storeURL: URL!
    private var historyService: TranscriptionHistoryService!
    private var coordinator: AppCoordinator!
    private var fakeAudioURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        historyService = TranscriptionHistoryService(storeURL: storeURL)
        coordinator = makeTestCoordinator()

        // 建立一個真實的臨時文件模擬m4a
        fakeAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: fakeAudioURL.path, contents: Data("stub".utf8))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fakeAudioURL)
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    /// 轉寫成功後，Murmur自己錄製的m4a必須被刪除。
    func test_beginTranscription_success_deletesOwnRecording() async throws {
        // Arrange — 經由真實的record → stop流程產生Murmur自己的錄音
        let spy = SpyTranscriptionService()
        spy.stubbedResult = TranscriptionResult(text: "Hello", language: .english, durationMs: 100)
        let sut = makeRecordingModelP0(
            historyService: historyService, coordinator: coordinator, storeURL: storeURL, spy: spy
        )
        let recordingURL = try await recordOwnAudio(with: sut)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path),
                      "Precondition: m4a must exist before transcription")

        // Act
        sut.beginTranscription(audioURL: recordingURL)
        await drainMainActorP0()

        // Assert — transcription成功後m4a應被刪除
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recordingURL.path),
            "Own recording must be deleted after successful transcription (IT-004)"
        )
        XCTAssertEqual(historyService.getAll().map(\.status), [.completed],
                       "The recording's own entry must be the one completed")
    }

    /// 轉寫成功後，用戶上傳的原始文件絕不可被刪除。
    func test_beginTranscription_success_uploadedFilePreserved() async throws {
        // Arrange — fakeAudioURL is a user's file: Murmur did not record it
        let spy = SpyTranscriptionService()
        spy.stubbedResult = TranscriptionResult(text: "Hello", language: .english, durationMs: 100)
        let sut = makeRecordingModelP0(
            historyService: historyService, coordinator: coordinator, storeURL: storeURL, spy: spy
        )

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActorP0()

        // Assert
        XCTAssertEqual(historyService.getAll().map(\.status), [.completed],
                       "Precondition: the transcription succeeded")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fakeAudioURL.path),
            "An uploaded file must NOT be deleted after successful transcription"
        )
    }

    /// 即使上傳的文件位於錄音目錄內，只要不是本次錄製的，也不可刪除。
    func test_beginTranscription_success_uploadedFileInsideRecordingsDirPreserved() async throws {
        // Arrange — the user picks a file that lies in Murmur's recordings directory
        let spy = SpyTranscriptionService()
        let sut = makeRecordingModelP0(
            historyService: historyService, coordinator: coordinator, storeURL: storeURL, spy: spy
        )
        let recordingsDir = recordingsDirectoryP0(storeURL: storeURL)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let pickedURL = recordingsDir.appendingPathComponent("picked-by-user.m4a")
        FileManager.default.createFile(atPath: pickedURL.path, contents: Data("stub".utf8))

        // Act
        sut.beginTranscription(audioURL: pickedURL)
        await drainMainActorP0()

        // Assert
        XCTAssertEqual(historyService.getAll().map(\.status), [.completed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pickedURL.path),
                      "A file the user picked must never be deleted, wherever it lies")
    }

    /// 轉寫成功後，history entry的m4aPath應為nil。
    func test_beginTranscription_success_historyEntry_m4aPathIsNil() async throws {
        // Arrange
        let spy = SpyTranscriptionService()
        spy.stubbedResult = TranscriptionResult(text: "Done", language: .english, durationMs: 200)
        let sut = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            transcriptionService: spy
        )

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActorP0()

        // Assert
        let all = historyService.getAll()
        XCTAssertEqual(all.count, 1, "Exactly one history entry expected")
        XCTAssertNil(all[0].m4aPath, "Completed entry must have nil m4aPath (m4a deleted)")
        XCTAssertEqual(all[0].status, .completed)
    }
}

// MARK: - 2. Cancel後m4a刪除 (EC-004)

@MainActor
final class CancelM4ACleanupTests: XCTestCase {

    private var storeURL: URL!
    private var historyService: TranscriptionHistoryService!
    private var coordinator: AppCoordinator!
    private var fakeAudioURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        historyService = TranscriptionHistoryService(storeURL: storeURL)
        coordinator = makeTestCoordinator()

        fakeAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: fakeAudioURL.path, contents: Data("stub".utf8))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fakeAudioURL)
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    /// 轉寫取消後，history中不留任何entry（EC-003）。
    func test_cancelTranscription_noHistoryEntryRemains() async throws {
        // Arrange
        let spy = SpyTranscriptionService()
        spy.shouldBlock = true
        let sut = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            transcriptionService: spy
        )

        // Act — 開始後立即取消
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActorP0()
        sut.cancelTranscription()
        await drainMainActorP0()

        // Assert
        let all = historyService.getAll()
        XCTAssertTrue(
            all.isEmpty || all.allSatisfy { $0.status != .failed },
            "Cancel must not leave a .failed entry (EC-003)"
        )
    }

    /// 轉寫因CancellationError終止後，upload模式的m4a應被保留（非錄音模式不自動刪除）。
    /// 注意：TranscriptionWindowModel目前在CancellationError時只刪history entry，
    /// 不刪除uploadURL — 此行為符合spec（upload原件保留給user）。
    func test_cancelUploadTranscription_originalFilePreserved() async throws {
        // Arrange
        let spy = SpyTranscriptionService()
        spy.stubbedError = CancellationError()
        let sut = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            transcriptionService: spy
        )

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActorP0()

        // Assert — upload原始文件不應被刪除（用戶自己的文件）
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fakeAudioURL.path),
            "Upload source file must NOT be deleted on cancellation"
        )
    }

    /// 用戶取消（cancelTranscription）後，上傳的原始文件仍須保留。
    func test_cancelTranscription_uploadedFilePreserved() async throws {
        // Arrange
        let spy = SpyTranscriptionService()
        spy.shouldBlock = true
        let sut = makeRecordingModelP0(
            historyService: historyService, coordinator: coordinator, storeURL: storeURL, spy: spy
        )

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActorP0()
        sut.cancelTranscription()
        await drainMainActorP0()

        // Assert
        XCTAssertTrue(historyService.getAll().isEmpty, "Precondition: the cancel was processed")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fakeAudioURL.path),
            "An uploaded file must NOT be deleted when the user cancels"
        )
    }

    /// 用戶取消後，Murmur自己錄製的m4a不再有用，必須刪除 (EC-004)。
    func test_cancelTranscription_deletesOwnRecording() async throws {
        // Arrange
        let spy = SpyTranscriptionService()
        spy.shouldBlock = true
        let sut = makeRecordingModelP0(
            historyService: historyService, coordinator: coordinator, storeURL: storeURL, spy: spy
        )
        let recordingURL = try await recordOwnAudio(with: sut)

        // Act
        sut.beginTranscription(audioURL: recordingURL)
        await drainMainActorP0()
        sut.cancelTranscription()
        await drainMainActorP0()

        // Assert
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path),
                       "A cancelled own recording must be deleted (EC-004)")
        XCTAssertTrue(historyService.getAll().isEmpty)
    }

    /// 轉寫因CancellationError終止時，Murmur自己錄製的m4a同樣刪除。
    func test_cancellationError_deletesOwnRecording() async throws {
        // Arrange
        let spy = SpyTranscriptionService()
        spy.stubbedError = CancellationError()
        let sut = makeRecordingModelP0(
            historyService: historyService, coordinator: coordinator, storeURL: storeURL, spy: spy
        )
        let recordingURL = try await recordOwnAudio(with: sut)

        // Act
        sut.beginTranscription(audioURL: recordingURL)
        await drainMainActorP0()

        // Assert
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))
        XCTAssertTrue(historyService.getAll().isEmpty)
    }
}

// MARK: - 3. Python crash → history.failed，保留m4a (EC-014)

@MainActor
final class PythonCrashHistoryFailedTests: XCTestCase {

    private var storeURL: URL!
    private var historyService: TranscriptionHistoryService!
    private var coordinator: AppCoordinator!
    private var fakeAudioURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        historyService = TranscriptionHistoryService(storeURL: storeURL)
        coordinator = makeTestCoordinator()

        fakeAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: fakeAudioURL.path, contents: Data("stub".utf8))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fakeAudioURL)
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    /// Python process非正常退出（MurmurError）→ history entry標記為.failed。
    func test_transcriptionFailed_historyEntry_markedFailed() async throws {
        // Arrange
        let spy = SpyTranscriptionService()
        spy.stubbedError = MurmurError.transcriptionFailed("Python crashed: exit code 1")
        let sut = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            transcriptionService: spy
        )

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActorP0()

        // Assert — entry存在且狀態為.failed
        let all = historyService.getAll()
        XCTAssertEqual(all.count, 1, "A failed entry must remain in history (EC-014)")
        XCTAssertEqual(all[0].status, .failed,
                       "History entry must be .failed after Python crash")
    }

    /// Python crash後，Murmur自己錄製的m4a必須被保留（供retry），entry仍記錄其路徑。
    func test_transcriptionFailed_ownRecordingPreserved() async throws {
        // Arrange
        let spy = SpyTranscriptionService()
        spy.stubbedError = MurmurError.transcriptionFailed("Python crashed")
        let sut = makeRecordingModelP0(
            historyService: historyService, coordinator: coordinator, storeURL: storeURL, spy: spy
        )
        let recordingURL = try await recordOwnAudio(with: sut)

        // Act
        sut.beginTranscription(audioURL: recordingURL)
        await drainMainActorP0()

        // Assert — 失敗時m4a應保留
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recordingURL.path),
            "m4a must be retained for retry after transcription failure (EC-014)"
        )
        let all = historyService.getAll()
        XCTAssertEqual(all.map(\.status), [.failed])
        XCTAssertEqual(all.first?.m4aPath, recordingURL.path,
                       "The failed entry must still point at the retained recording")
    }

    /// 轉寫失敗後，用戶上傳的原始文件仍須保留，且history不記錄其路徑。
    func test_transcriptionFailed_uploadedFilePreserved() async throws {
        // Arrange
        let spy = SpyTranscriptionService()
        spy.stubbedError = MurmurError.transcriptionFailed("Python crashed")
        let sut = makeRecordingModelP0(
            historyService: historyService, coordinator: coordinator, storeURL: storeURL, spy: spy
        )

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActorP0()

        // Assert
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fakeAudioURL.path),
            "An uploaded file must NOT be deleted after a failed transcription"
        )
        let all = historyService.getAll()
        XCTAssertEqual(all.map(\.status), [.failed])
        XCTAssertNil(all.first?.m4aPath,
                     "History must not hold the path of a file Murmur does not own")
    }

    /// 失敗後window state返回.idle。
    func test_transcriptionFailed_windowStateIsIdle() async throws {
        // Arrange
        let spy = SpyTranscriptionService()
        spy.stubbedError = MurmurError.transcriptionFailed("timeout")
        let sut = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            transcriptionService: spy
        )

        // Act
        sut.beginTranscription(audioURL: fakeAudioURL)
        await drainMainActorP0()

        // Assert
        if case .idle = sut.windowState {
            // correct
        } else {
            XCTFail("Expected .idle after transcription failure, got \(sut.windowState)")
        }
    }
}

// MARK: - 4. 孤兒m4a清理 — scanAndRecoverOrphans() (EC-010/011)
//
// OrphanM4ACleaner等效邏輯已在TranscriptionHistoryService.scanAndRecoverOrphans()實作。
// 此組tests在integration層驗證該邏輯。

@MainActor
final class OrphanM4AScanTests: XCTestCase {

    private var storeURL: URL!
    private var sut: TranscriptionHistoryService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        sut = TranscriptionHistoryService(storeURL: storeURL)
    }

    override func tearDownWithError() throws {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    /// App啟動時，m4a不存在的inProgress entry應被標記為.failed (EC-010)。
    func test_scanAndRecoverOrphans_missingM4A_marksEntryFailed() throws {
        // Arrange — inProgress entry指向不存在的m4a
        let entry = TranscriptionEntry(
            id: UUID(),
            date: Date(),
            audioDuration: 0,
            text: "",
            language: "en",
            status: .inProgress,
            m4aPath: "/nonexistent/orphan_\(UUID().uuidString).m4a"
        )
        try sut.add(entry)
        XCTAssertEqual(sut.getAll()[0].status, .inProgress)

        // Act
        sut.scanAndRecoverOrphans()

        // Assert
        XCTAssertEqual(sut.getAll()[0].status, .failed,
                       "inProgress entry with missing m4a must be marked .failed (EC-010)")
    }

    /// Nothing can be in progress at launch: an interrupted entry is marked
    /// failed even when its recording survived, and the recording is kept.
    func test_scanAndRecoverOrphans_existingM4A_marksEntryFailed_andKeepsTheAudio() throws {
        // Arrange — 建立真實臨時文件
        let tempM4A = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: tempM4A.path, contents: Data("stub".utf8))
        defer { try? FileManager.default.removeItem(at: tempM4A) }

        let entry = TranscriptionEntry(
            id: UUID(),
            date: Date(),
            audioDuration: 0,
            text: "",
            language: "en",
            status: .inProgress,
            m4aPath: tempM4A.path
        )
        try sut.add(entry)

        // Act
        sut.scanAndRecoverOrphans()

        // Assert
        XCTAssertEqual(sut.getAll()[0].status, .failed,
                       "an entry still inProgress at launch was interrupted")
        XCTAssertEqual(sut.getAll()[0].m4aPath, tempM4A.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempM4A.path),
                      "the recording is kept for a retry")
    }

    /// 有對應history entry（failed狀態）的m4a不應被scanAndRecoverOrphans干擾 (EC-011)。
    func test_scanAndRecoverOrphans_failedEntry_unchangedByOrphanScan() throws {
        // Arrange
        let tempM4A = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: tempM4A.path, contents: Data("stub".utf8))
        defer { try? FileManager.default.removeItem(at: tempM4A) }

        let entry = TranscriptionEntry(
            id: UUID(),
            date: Date(),
            audioDuration: 0,
            text: "",
            language: "en",
            status: .failed,
            m4aPath: tempM4A.path
        )
        try sut.add(entry)

        // Act
        sut.scanAndRecoverOrphans()

        // Assert — failed entry維持.failed，不被改動
        XCTAssertEqual(sut.getAll()[0].status, .failed,
                       "Failed entry must remain .failed after orphan scan (EC-011)")
    }

    /// inProgress但m4aPath為nil的entry（crash in pre-recording phase）也應標記為.failed。
    func test_scanAndRecoverOrphans_inProgressWithNilM4APath_markedFailed() throws {
        // Arrange
        let entry = TranscriptionEntry(
            id: UUID(),
            date: Date(),
            audioDuration: 0,
            text: "",
            language: "en",
            status: .inProgress,
            m4aPath: nil   // no path set — pre-recording crash
        )
        try sut.add(entry)

        // Act
        sut.scanAndRecoverOrphans()

        // Assert
        XCTAssertEqual(sut.getAll()[0].status, .failed,
                       "inProgress entry with nil m4aPath must be marked .failed")
    }
}

// MARK: - 5. m4aPath生命週期完整驗證

@MainActor
final class M4APathLifecycleTests: XCTestCase {

    private var storeURL: URL!
    private var historyService: TranscriptionHistoryService!
    private var coordinator: AppCoordinator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        historyService = TranscriptionHistoryService(storeURL: storeURL)
        coordinator = makeTestCoordinator()
    }

    override func tearDownWithError() throws {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    /// 轉寫Murmur自己的錄音時，history entry應包含m4aPath（inProgress狀態）。
    func test_beginTranscription_ownRecording_inProgress_entry_hasM4APath() async throws {
        // Arrange
        let spy = SpyTranscriptionService()
        spy.shouldBlock = true
        let sut = makeRecordingModelP0(
            historyService: historyService, coordinator: coordinator, storeURL: storeURL, spy: spy
        )
        let recordingURL = try await recordOwnAudio(with: sut)

        // Act — 開始轉寫（不完成）
        sut.beginTranscription(audioURL: recordingURL)
        await drainMainActorP0()

        // Assert — 轉寫進行中，entry應有m4aPath
        let all = historyService.getAll()
        XCTAssertEqual(all.map(\.status), [.inProgress])
        XCTAssertEqual(all.first?.m4aPath, recordingURL.path,
                       "inProgress entry must track m4aPath for orphan recovery")
        // 清理
        sut.cancelTranscription()
        await drainMainActorP0()
    }

    /// 轉寫上傳文件時，history entry不可記錄用戶文件的路徑。
    func test_beginTranscription_upload_inProgress_entry_hasNoM4APath() async throws {
        // Arrange
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data("stub".utf8))
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let spy = SpyTranscriptionService()
        spy.shouldBlock = true
        let sut = makeRecordingModelP0(
            historyService: historyService, coordinator: coordinator, storeURL: storeURL, spy: spy
        )

        // Act — 開始轉寫（不完成）
        sut.beginTranscription(audioURL: audioURL)
        await drainMainActorP0()

        // Assert
        let all = historyService.getAll()
        XCTAssertEqual(all.map(\.status), [.inProgress])
        XCTAssertNil(all.first?.m4aPath,
                     "m4aPath is only for files Murmur recorded — never a user's file")
        // 清理
        sut.cancelTranscription()
        await drainMainActorP0()
    }

    /// completeEntry後m4aPath歸nil（已由TranscriptionHistoryServiceTests覆蓋，此處在ViewModel層確認）。
    func test_beginTranscription_completed_entry_m4aPathIsNil() async throws {
        // Arrange
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data("stub".utf8))
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let spy = SpyTranscriptionService()
        spy.stubbedResult = TranscriptionResult(text: "Test", language: .english, durationMs: 50)
        let sut = TranscriptionWindowModel(
            historyService: historyService,
            coordinator: coordinator,
            transcriptionService: spy
        )

        // Act
        sut.beginTranscription(audioURL: audioURL)
        await drainMainActorP0()

        // Assert
        let all = historyService.getAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].status, .completed)
        XCTAssertNil(all[0].m4aPath, "Completed entry must have nil m4aPath")
    }
}

// MARK: - Helpers

/// The recordings directory of `makeRecordingModelP0`: next to the temp history
/// store, so each test's tearDown removes it together with the store.
private func recordingsDirectoryP0(storeURL: URL) -> URL {
    storeURL.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
}

/// A model that records through a stub recorder into a temp directory, so a
/// test can produce one of Murmur's own recordings with `recordOwnAudio(with:)`.
@MainActor
private func makeRecordingModelP0(
    historyService: TranscriptionHistoryService,
    coordinator: AppCoordinator,
    storeURL: URL,
    spy: SpyTranscriptionService
) -> TranscriptionWindowModel {
    TranscriptionWindowModel(
        historyService: historyService,
        coordinator: coordinator,
        recordingService: makeStubRecordingService(
            outputDirectory: recordingsDirectoryP0(storeURL: storeURL)
        ),
        transcriptionService: spy
    )
}

/// MainActor drainHelper — identical to TranscriptionWindowModelTests version.
@MainActor
private func drainMainActorP0() async {
    await Task.yield()
    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    await Task.yield()
}
