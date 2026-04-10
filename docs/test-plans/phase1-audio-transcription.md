# Phase 1 Test Plan — Audio Transcription (V2)

**Author:** @QA
**Status:** RDY
**Date:** 2026-04-10
**Spec:** docs/specs/meeting-transcription.md (rev 8)
**UX:** docs/design/audio-transcription-ux.md (rev 2)
**Handoff in:** 030_EN_QA_chunked-transcribe-poc, 031_PM_ALL_phase0-final-go

---

## 覆蓋範圍摘要

| 類別 | 測試數 | 框架 |
|------|--------|------|
| Unit Tests (Swift) | 18 | XCTest |
| Unit Tests (Python) | 已有（mirror確認） | unittest |
| Integration Tests | 12 | XCTest + XCTAsyncExpectation |
| UI Tests | 16 | XCUITest |
| Edge Case Tests | 14 | XCTest / XCUITest |
| **合計** | **60** | — |

---

## 1. Unit Tests

### 1.1 TranscriptionService.transcribeLong() — Swift (XCTest)

**文件：** `MurmurTests/TranscriptionServiceTests.swift`

#### UT-001 — progress回調接收正確chunk序號與百分比

```swift
func test_transcribeLong_progressCallback_receivesChunkIndexAndPercent() async throws {
    // Arrange
    let mockProcess = MockPythonProcess()
    mockProcess.stubbedLines = [
        #"{"type":"progress","chunk":1,"total":4,"text":"Hello"}"#,
        #"{"type":"progress","chunk":2,"total":4,"text":"Hello world"}"#,
        #"{"type":"result","text":"Hello world done","language":"en","duration_ms":5000,"chunks":4}"#,
    ]
    let sut = TranscriptionService(processFactory: mockProcess)
    var received: [(chunk: Int, total: Int)] = []

    // Act
    _ = try await sut.transcribeLong(
        audioPath: URL(fileURLWithPath: "/tmp/fake.m4a"),
        language: "en"
    ) { progress in
        received.append((progress.chunk, progress.total))
    }

    // Assert
    XCTAssertEqual(received.count, 2)
    XCTAssertEqual(received[0].chunk, 1)
    XCTAssertEqual(received[0].total, 4)
    XCTAssertEqual(received[1].chunk, 2)
}
```

#### UT-002 — progress百分比遞增，不後退

```swift
func test_transcribeLong_progressPercent_isMonotonicallyIncreasing() async throws {
    // Arrange: 5 progress events in order
    let mockProcess = MockPythonProcess()
    mockProcess.stubbedLines = (1...5).map {
        #"{"type":"progress","chunk":\#($0),"total":5,"text":"t"}"#
    } + [#"{"type":"result","text":"done","language":"en","duration_ms":1000,"chunks":5}"#]
    let sut = TranscriptionService(processFactory: mockProcess)
    var percents: [Double] = []

    // Act
    _ = try await sut.transcribeLong(
        audioPath: URL(fileURLWithPath: "/tmp/fake.m4a"),
        language: "en"
    ) { percents.append(Double($0.chunk) / Double($0.total)) }

    // Assert
    XCTAssertEqual(percents, percents.sorted())
}
```

#### UT-003 — cancel：Task取消後pipeline停止，不繼續讀取後續行

```swift
func test_transcribeLong_taskCancellation_stopsPipeline() async throws {
    // Arrange
    let mockProcess = MockPythonProcess()
    mockProcess.stubbedLines = [
        #"{"type":"progress","chunk":1,"total":10,"text":"a"}"#,
        // 後續9行永不到達
    ]
    mockProcess.blockAfterFirstLine = true   // 第2行起阻塞直到cancel
    let sut = TranscriptionService(processFactory: mockProcess)

    // Act
    let task = Task {
        try await sut.transcribeLong(
            audioPath: URL(fileURLWithPath: "/tmp/fake.m4a"),
            language: "en",
            onProgress: { _ in }
        )
    }
    try await Task.sleep(nanoseconds: 50_000_000) // 50ms — 讓第1行先到
    task.cancel()

    // Assert
    do {
        _ = try await task.value
        XCTFail("Expected cancellation error")
    } catch is CancellationError {
        // expected
    }
    XCTAssertTrue(mockProcess.didTerminate, "Python process must be terminated on cancel")
}
```

#### UT-004 — cancel後voice input狀態恢復為active

```swift
func test_transcribeLong_cancel_resumesVoiceInput() async throws {
    // Arrange
    let mockVoiceInput = MockVoiceInputController()
    let sut = TranscriptionService(
        processFactory: MockPythonProcess.cancellingAfterFirstChunk(),
        voiceInputController: mockVoiceInput
    )

    // Act
    let task = Task {
        try? await sut.transcribeLong(
            audioPath: URL(fileURLWithPath: "/tmp/fake.m4a"),
            language: "en", onProgress: { _ in }
        )
    }
    task.cancel()
    _ = await task.result

    // Assert
    XCTAssertEqual(mockVoiceInput.state, .active)
}
```

#### UT-005 — Python process返回error JSON，方法拋出TranscriptionError

```swift
func test_transcribeLong_errorJSON_throwsTranscriptionError() async throws {
    // Arrange
    let mockProcess = MockPythonProcess()
    mockProcess.stubbedLines = [
        #"{"type":"error","message":"model not loaded","code":"MODEL_NOT_READY"}"#
    ]
    let sut = TranscriptionService(processFactory: mockProcess)

    // Act & Assert
    do {
        _ = try await sut.transcribeLong(
            audioPath: URL(fileURLWithPath: "/tmp/fake.m4a"),
            language: "en", onProgress: { _ in }
        )
        XCTFail("Expected TranscriptionError")
    } catch let err as TranscriptionError {
        XCTAssertEqual(err.code, "MODEL_NOT_READY")
    }
}
```

#### UT-006 — 轉寫完成後voice input自動恢復

```swift
func test_transcribeLong_completion_resumesVoiceInput() async throws {
    // Arrange
    let mockVoiceInput = MockVoiceInputController()
    mockVoiceInput.state = .paused
    let mockProcess = MockPythonProcess.successWith(chunks: 3)
    let sut = TranscriptionService(
        processFactory: mockProcess,
        voiceInputController: mockVoiceInput
    )

    // Act
    _ = try await sut.transcribeLong(
        audioPath: URL(fileURLWithPath: "/tmp/fake.m4a"),
        language: "en", onProgress: { _ in }
    )

    // Assert
    XCTAssertEqual(mockVoiceInput.state, .active)
}
```

---

### 1.2 Chunk Boundary計算 — Swift mirror of Python unit tests

**文件：** `MurmurTests/ChunkBoundaryTests.swift`
**對應Python：** `Murmur/Scripts/test_chunked_transcribe.py` Layer 1

#### UT-007 — 整除情況：chunks數量正確

```swift
func test_computeChunkBoundaries_exactDivision_correctCount() {
    // 60秒音頻，30秒chunk，5秒overlap
    // total_samples=960000 (16kHz), chunk=480000, overlap=80000
    let boundaries = ChunkBoundaryCalculator.compute(
        totalSamples: 960_000, chunkSamples: 480_000, overlapSamples: 80_000
    )
    // 預期：2 chunks（與Python test_chunk_boundaries_exact_division一致）
    XCTAssertEqual(boundaries.count, 2)
    XCTAssertEqual(boundaries[0].start, 0)
    XCTAssertEqual(boundaries[0].end, 480_000)
}
```

#### UT-008 — 不整除情況：尾chunk含餘數

```swift
func test_computeChunkBoundaries_remainder_lastChunkCoversRemainder() {
    // 75秒音頻（1_200_000 samples）, 30秒chunk
    let boundaries = ChunkBoundaryCalculator.compute(
        totalSamples: 1_200_000, chunkSamples: 480_000, overlapSamples: 80_000
    )
    XCTAssertGreaterThanOrEqual(boundaries.last!.end, 1_200_000)
    // 尾chunk不超過總長度
    XCTAssertEqual(boundaries.last!.end, 1_200_000)
}
```

#### UT-009 — 極短音頻（短於一個chunk）：返回單chunk

```swift
func test_computeChunkBoundaries_audioShorterThanChunk_returnsSingleChunk() {
    let boundaries = ChunkBoundaryCalculator.compute(
        totalSamples: 80_000,   // 5秒
        chunkSamples: 480_000,  // 30秒
        overlapSamples: 80_000
    )
    XCTAssertEqual(boundaries.count, 1)
    XCTAssertEqual(boundaries[0].start, 0)
    XCTAssertEqual(boundaries[0].end, 80_000)
}
```

#### UT-010 — chunk_sec < overlap_sec：拋出錯誤

```swift
func test_computeChunkBoundaries_overlapExceedsChunk_throwsInvalidArgument() {
    XCTAssertThrowsError(
        try ChunkBoundaryCalculator.computeValidated(
            totalSamples: 960_000, chunkSamples: 80_000, overlapSamples: 160_000
        )
    ) { error in
        XCTAssertEqual((error as? ChunkError), .overlapExceedsChunk)
    }
}
```

#### UT-011 — 零長度音頻：拋出錯誤

```swift
func test_computeChunkBoundaries_zeroLength_throwsInvalidArgument() {
    XCTAssertThrowsError(
        try ChunkBoundaryCalculator.computeValidated(
            totalSamples: 0, chunkSamples: 480_000, overlapSamples: 80_000
        )
    ) { error in
        XCTAssertEqual((error as? ChunkError), .emptyAudio)
    }
}
```

---

### 1.3 TranscriptionHistory CRUD

**文件：** `MurmurTests/TranscriptionHistoryTests.swift`

#### UT-012 — 新增記錄後count遞增

```swift
func test_history_add_incrementsCount() {
    let sut = TranscriptionHistory()
    sut.add(TranscriptionEntry.fixture())
    XCTAssertEqual(sut.count, 1)
}
```

#### UT-013 — 50筆上限：第51筆新增後最舊項被淘汰

```swift
func test_history_add_at51stEntry_evictsOldest() {
    let sut = TranscriptionHistory()
    let oldest = TranscriptionEntry.fixture(id: "oldest", date: .distantPast)
    sut.add(oldest)
    for _ in 1...50 { sut.add(TranscriptionEntry.fixture()) }
    // oldest應已被淘汰
    XCTAssertEqual(sut.count, 50)
    XCTAssertNil(sut.entry(withID: "oldest"))
}
```

#### UT-014 — delete單項：刪除後無法找到，count減少

```swift
func test_history_deleteByID_removesEntry() {
    let sut = TranscriptionHistory()
    let entry = TranscriptionEntry.fixture(id: "target")
    sut.add(entry)
    sut.delete(id: "target")
    XCTAssertNil(sut.entry(withID: "target"))
    XCTAssertEqual(sut.count, 0)
}
```

#### UT-015 — delete不存在的ID：無crash，count不變

```swift
func test_history_deleteNonexistentID_isNoOp() {
    let sut = TranscriptionHistory()
    sut.add(TranscriptionEntry.fixture())
    XCTAssertNoThrow(sut.delete(id: "ghost"))
    XCTAssertEqual(sut.count, 1)
}
```

#### UT-016 — clearAll：count歸零

```swift
func test_history_clearAll_removesAllEntries() {
    let sut = TranscriptionHistory()
    for _ in 1...10 { sut.add(TranscriptionEntry.fixture()) }
    sut.clearAll()
    XCTAssertEqual(sut.count, 0)
}
```

---

### 1.4 Voice Input Pause/Resume State Machine

**文件：** `MurmurTests/VoiceInputStateMachineTests.swift`

#### UT-017 — 轉寫開始時voice input自動暫停

```swift
func test_voiceInput_whenTranscriptionStarts_pausesAutomatically() {
    let sut = VoiceInputController()
    sut.state = .active
    sut.notifyTranscriptionWillStart()
    XCTAssertEqual(sut.state, .pausedForTranscription)
}
```

#### UT-018 — 轉寫完成時voice input自動恢復

```swift
func test_voiceInput_whenTranscriptionCompletes_resumesAutomatically() {
    let sut = VoiceInputController()
    sut.state = .pausedForTranscription
    sut.notifyTranscriptionDidEnd()
    XCTAssertEqual(sut.state, .active)
}
```

#### UT-019 — 轉寫cancel後voice input恢復

```swift
func test_voiceInput_whenTranscriptionCancelled_resumesImmediately() {
    let sut = VoiceInputController()
    sut.state = .pausedForTranscription
    sut.notifyTranscriptionDidCancel()
    XCTAssertEqual(sut.state, .active)
}
```

#### UT-020 — 轉寫前voice input若已是idle（從未啟動），不應切為active

```swift
func test_voiceInput_transcriptionEnds_ifWasIdleBeforePause_remainsIdle() {
    // 若錄音開始時voice input並未在active，完成後應維持idle
    let sut = VoiceInputController()
    sut.state = .idle
    sut.notifyTranscriptionWillStart()
    XCTAssertEqual(sut.state, .idle, "Idle voice input should not be paused")
    sut.notifyTranscriptionDidEnd()
    XCTAssertEqual(sut.state, .idle, "Should remain idle after transcription ends")
}
```

---

### 1.5 磁盤空間檢查

**文件：** `MurmurTests/DiskSpaceCheckerTests.swift`

#### UT-021 — 可用空間 < 1GB：拒絕錄音

```swift
func test_diskSpace_lessThan1GB_refusesRecording() {
    let sut = DiskSpaceChecker(availableBytes: { 900 * 1024 * 1024 }) // 900MB
    XCTAssertFalse(sut.canStartRecording)
    XCTAssertEqual(sut.refusalReason, .insufficientFreeSpace)
}
```

#### UT-022 — 可用空間 >= 1GB：允許錄音

```swift
func test_diskSpace_exactly1GB_allowsRecording() {
    let sut = DiskSpaceChecker(availableBytes: { 1024 * 1024 * 1024 })
    XCTAssertTrue(sut.canStartRecording)
}
```

#### UT-023 — m4a cap已達80%（1.6GB）：發出警告

```swift
func test_diskSpace_m4aAt80PercentCap_emitsWarning() {
    let sut = DiskSpaceChecker(
        availableBytes: { 10 * 1024 * 1024 * 1024 },  // 10GB free — 非bottleneck
        currentM4aUsageBytes: { 1_600 * 1024 * 1024 }  // 1.6GB
    )
    XCTAssertEqual(sut.m4aCapStatus, .warning)
}
```

#### UT-024 — m4a cap已達100%（2GB）：拒絕新錄音

```swift
func test_diskSpace_m4aAt100PercentCap_refusesNewRecording() {
    let sut = DiskSpaceChecker(
        availableBytes: { 10 * 1024 * 1024 * 1024 },
        currentM4aUsageBytes: { 2_048 * 1024 * 1024 }  // 2GB
    )
    XCTAssertFalse(sut.canStartRecording)
    XCTAssertEqual(sut.refusalReason, .m4aCapReached)
}
```

---

## 2. Integration Tests

**文件：** `MurmurTests/IntegrationTests/`
**前提：** 需Python環境及`transcribe.py`可執行；不需真實Cohere模型（mock backend）。

### 2.1 Python subprocess — transcribe_long命令

#### IT-001 — 發送transcribe_long命令，接收multi-line progress + result

```swift
func test_subprocess_transcribeLong_receivesProgressThenResult() async throws {
    // 使用真實Python process，mock audio file (5秒白噪音WAV)
    let sut = PythonBridgeIntegration(scriptPath: transcribePyPath)
    var progressEvents: [ProgressEvent] = []

    let result = try await sut.sendCommand(
        .transcribeLong(audioPath: mockAudioURL, language: "en")
    ) { event in progressEvents.append(event) }

    XCTAssertFalse(progressEvents.isEmpty, "At least 1 progress event expected")
    XCTAssertFalse(result.text.isEmpty, "Result text must not be empty")
    XCTAssertEqual(result.type, "result")
}
```

#### IT-002 — model未載入時，error JSON正確返回（不crash）

```swift
func test_subprocess_transcribeLong_modelNotLoaded_returnsErrorJSON() async throws {
    // 使用故意無效的model path觸發model-not-loaded場景
    let sut = PythonBridgeIntegration(scriptPath: transcribePyPath, modelPath: "/nonexistent")
    do {
        _ = try await sut.sendCommand(.transcribeLong(audioPath: mockAudioURL, language: "en")) { _ in }
        XCTFail("Expected error")
    } catch let err as PythonBridgeError {
        XCTAssertNotNil(err.message)
        // 確認進程未crash（exit code非segfault）
        XCTAssertNotEqual(err.exitCode, -11)
    }
}
```

### 2.2 m4a錄音→轉寫 Full Pipeline

#### IT-003 — 錄音5秒→停止→transcribeLong→得到non-empty transcript

```swift
func test_pipeline_record5SecThenTranscribe_producesTranscript() async throws {
    let recorder = AudioRecorder()
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory() + "test_\(UUID()).m4a")

    try recorder.start(outputURL: outputURL)
    try await Task.sleep(nanoseconds: 5_000_000_000)
    let duration = try recorder.stop()

    XCTAssertGreaterThan(duration, 4.0)

    let service = TranscriptionService(scriptPath: transcribePyPath)
    let result = try await service.transcribeLong(audioPath: outputURL, language: "en") { _ in }

    XCTAssertFalse(result.text.isEmpty)
    // 清理
    try? FileManager.default.removeItem(at: outputURL)
}
```

#### IT-004 — 轉寫完成後m4a自動刪除

```swift
func test_pipeline_transcribeComplete_m4aDeleted() async throws {
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory() + "del_test_\(UUID()).m4a")
    // 建立假m4a（5秒靜音）
    try TestAudioFixture.createSilentM4A(at: outputURL, durationSec: 5)
    let service = TranscriptionService(scriptPath: transcribePyPath)

    _ = try await service.transcribeLong(audioPath: outputURL, language: "en") { _ in }

    XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path),
                   "m4a must be deleted after successful transcription")
}
```

### 2.3 文件上傳→格式驗證→轉寫

#### IT-005 — 有效.mp3文件：通過驗證，進入轉寫

```swift
func test_fileUpload_validMp3_passesValidation() throws {
    let mp3URL = TestAudioFixture.mp3URL
    let validator = AudioFileValidator()
    let result = try validator.validate(url: mp3URL)
    XCTAssertNoThrow(result)
    XCTAssertEqual(result.format, .mp3)
}
```

#### IT-006 — .wav文件：驗證拒絕，返回unsupportedFormat錯誤

```swift
func test_fileUpload_wavFile_rejectedWithUnsupportedFormat() {
    let wavURL = TestAudioFixture.wavURL
    let validator = AudioFileValidator()
    XCTAssertThrowsError(try validator.validate(url: wavURL)) { error in
        XCTAssertEqual((error as? AudioValidationError), .unsupportedFormat)
    }
}
```

#### IT-007 — 超過2小時文件：驗證拒絕，返回durationExceedsLimit

```swift
func test_fileUpload_durationOver2Hr_rejectedWithDurationError() {
    let longFileURL = TestAudioFixture.dummyURL(duration: 7201)  // 2hr1s
    let validator = AudioFileValidator()
    XCTAssertThrowsError(try validator.validate(url: longFileURL)) { error in
        XCTAssertEqual((error as? AudioValidationError), .durationExceedsLimit)
    }
}
```

### 2.4 activationPolicy切換

#### IT-008 — 開啟main window時policy切為.regular

```swift
@MainActor
func test_activationPolicy_mainWindowOpen_switchesToRegular() throws {
    let controller = AppWindowController()
    controller.openMainWindow()
    XCTAssertEqual(NSApp.activationPolicy(), .regular)
}
```

#### IT-009 — 關閉main window時policy切回.accessory

```swift
@MainActor
func test_activationPolicy_mainWindowClose_revertsToAccessory() throws {
    let controller = AppWindowController()
    controller.openMainWindow()
    controller.closeMainWindow()
    // 需等待runloop一圈確認切換已完成
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(NSApp.activationPolicy(), .accessory)
}
```

### 2.5 History Persistence

#### IT-010 — 新增history entry後重啟（模擬）仍可讀取

```swift
func test_historyPersistence_addAndReload_entryPreserved() {
    let store = TranscriptionHistoryStore(suiteName: "test.\(UUID())")
    let entry = TranscriptionEntry.fixture(id: "persist-me", text: "hello world")
    store.save(entry)

    // 模擬重啟：建立新store實例讀取相同suite
    let freshStore = TranscriptionHistoryStore(suiteName: store.suiteName)
    let loaded = freshStore.entry(withID: "persist-me")

    XCTAssertNotNil(loaded)
    XCTAssertEqual(loaded?.text, "hello world")
    store.nukeForTesting()
}
```

#### IT-011 — delete history entry後重啟，項目消失

```swift
func test_historyPersistence_deleteAndReload_entryGone() {
    let store = TranscriptionHistoryStore(suiteName: "test.\(UUID())")
    store.save(TranscriptionEntry.fixture(id: "to-delete"))
    store.delete(id: "to-delete")

    let freshStore = TranscriptionHistoryStore(suiteName: store.suiteName)
    XCTAssertNil(freshStore.entry(withID: "to-delete"))
    store.nukeForTesting()
}
```

#### IT-012 — 50筆上限跨session保持

```swift
func test_historyPersistence_50EntryLimit_enforcedAcrossReloads() {
    let store = TranscriptionHistoryStore(suiteName: "test.\(UUID())")
    for i in 1...55 { store.save(TranscriptionEntry.fixture(id: "e\(i)")) }

    let freshStore = TranscriptionHistoryStore(suiteName: store.suiteName)
    XCTAssertLessThanOrEqual(freshStore.allEntries().count, 50)
    store.nukeForTesting()
}
```

---

## 3. UI Tests (XCUITest)

**文件：** `MurmurUITests/AudioTranscriptionUITests.swift`
**前提：** App以UI test configuration啟動，Python bridge stub返回即時mock結果。

### 3.1 Main Window Open/Close

#### UI-001 — 全局快捷鍵 Cmd+Shift+T 開啟main window

```swift
func test_globalHotkey_cmdShiftT_opensMainWindow() {
    app.typeKey("t", modifierFlags: [.command, .shift])
    XCTAssertTrue(app.windows["Audio Transcription"].waitForExistence(timeout: 2))
}
```

#### UI-002 — 關閉main window後Dock icon消失

```swift
func test_closeMainWindow_dockIconHides() {
    openMainWindow()
    app.windows["Audio Transcription"].buttons[XCUIIdentifierCloseWindow].click()
    // Dock icon之有無：用activationPolicy間接確認（UI test無法直接查Dock）
    // 驗證app無longer出現於Cmd+Tab（此為manual test補充）
    XCTAssertFalse(app.windows["Audio Transcription"].exists)
}
```

#### UI-003 — Cmd+N在result頁回到Idle

```swift
func test_cmdN_fromResultView_returnsToIdle() {
    navigateToResultView()
    app.typeKey("n", modifierFlags: .command)
    XCTAssertTrue(app.buttons["Record Audio"].waitForExistence(timeout: 2))
}
```

### 3.2 錄音流程

#### UI-004 — 點擊Record → 進入錄音中，計時器遞增

```swift
func test_recordFlow_tapRecord_timerCounts() {
    openMainWindow()
    app.buttons["Record Audio"].click()
    let timer = app.staticTexts["RecordingTimer"]
    XCTAssertTrue(timer.waitForExistence(timeout: 2))
    let t1 = timer.label
    Thread.sleep(forTimeInterval: 2)
    XCTAssertNotEqual(timer.label, t1, "Timer must advance")
}
```

#### UI-005 — Stop Recording → 進入確認頁，顯示Duration與Est. time

```swift
func test_recordFlow_tapStop_showsConfirmScreen() {
    openMainWindow()
    app.buttons["Record Audio"].click()
    Thread.sleep(forTimeInterval: 1)
    app.buttons["Stop Recording"].click()
    XCTAssertTrue(app.staticTexts["Recording complete"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts.matching(identifier: "EstimatedTime").firstMatch.exists)
}
```

#### UI-006 — Confirm → 進入Transcribing，進度條可見

```swift
func test_recordFlow_confirmTranscription_showsProgressBar() {
    navigateToConfirmScreen()
    app.buttons["Start Transcription"].click()
    XCTAssertTrue(app.progressIndicators["TranscriptionProgress"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Voice input paused"].exists)
}
```

#### UI-007 — 轉寫完成 → 進入Result頁，文字可選取

```swift
func test_recordFlow_transcriptionComplete_showsSelectableText() {
    navigateToTranscribingScreen()
    // stub使mock process立即完成
    let textView = app.textViews["TranscriptTextView"]
    XCTAssertTrue(textView.waitForExistence(timeout: 10))
    XCTAssertFalse(textView.value as? String == "", "Transcript text must not be empty")
}
```

### 3.3 上傳流程

#### UI-008 — 拖拽有效.m4a文件至main area → 進入Validate → 顯示確認頁

```swift
func test_uploadFlow_dragValidM4A_showsConfirmScreen() {
    openMainWindow()
    let fileURL = TestAudioFixture.shortM4AURL
    app.windows["Audio Transcription"].dragAndDrop(from: fileURL)
    XCTAssertTrue(app.staticTexts["Ready to transcribe"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Voice input will pause during transcription."].exists)
}
```

#### UI-009 — 拖拽.wav文件 → 顯示unsupported format錯誤

```swift
func test_uploadFlow_dragWavFile_showsUnsupportedError() {
    openMainWindow()
    app.windows["Audio Transcription"].dragAndDrop(from: TestAudioFixture.wavURL)
    let errorLabel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Unsupported format'")).firstMatch
    XCTAssertTrue(errorLabel.waitForExistence(timeout: 3))
}
```

#### UI-010 — 點擊Cancel於確認頁 → 回到Idle，voice input恢復

```swift
func test_uploadFlow_cancelAtConfirm_returnsToIdle() {
    navigateToUploadConfirmScreen()
    app.buttons["Cancel"].click()
    XCTAssertTrue(app.buttons["Record Audio"].waitForExistence(timeout: 2))
}
```

### 3.4 Progress UI

#### UI-011 — 進度條百分比標籤隨進度更新

```swift
func test_progressUI_percentLabel_updatesWithProgress() {
    navigateToTranscribingScreen()
    let pctLabel = app.staticTexts["ProgressPercent"]
    let initial = pctLabel.label
    // 等待mock process發送下一progress event
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertNotEqual(pctLabel.label, initial, "Percent label must update")
}
```

#### UI-012 — 點擊Cancel → inline確認對話框出現，含進度百分比

```swift
func test_progressUI_tapCancel_showsInlineConfirmWithPercent() {
    navigateToTranscribingScreen()
    app.buttons["Cancel"].click()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Progress will be lost'")).firstMatch.waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["Cancel anyway"].exists)
    XCTAssertTrue(app.buttons["Keep going"].exists)
}
```

### 3.5 Transcript View操作

#### UI-013 — Copy All複製全文，按鈕短暫顯示「Copied!」

```swift
func test_transcriptView_copyAll_buttonShowsCopied() {
    navigateToResultView()
    app.buttons["Copy All"].click()
    XCTAssertTrue(app.staticTexts["Copied!"].waitForExistence(timeout: 2))
    // 1.5秒後回復
    Thread.sleep(forTimeInterval: 2)
    XCTAssertFalse(app.staticTexts["Copied!"].exists)
}
```

#### UI-014 — Cmd+F觸發文內搜尋（NSTextView原生）

```swift
func test_transcriptView_cmdF_activatesSearch() {
    navigateToResultView()
    app.typeKey("f", modifierFlags: .command)
    // NSTextView原生search bar出現
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 2))
}
```

### 3.6 Sidebar Navigation

#### UI-015 — 歷史列表顯示日期分組及預覽文字

```swift
func test_sidebar_historyList_showsDateGroupsAndPreview() {
    seedHistory(count: 3)
    openMainWindow()
    XCTAssertTrue(app.staticTexts["Today"].exists)
    // 每個history item顯示時間及preview
    let cells = app.cells.matching(identifier: "HistoryCell")
    XCTAssertGreaterThanOrEqual(cells.count, 1)
    XCTAssertFalse((cells.firstMatch.staticTexts["PreviewText"].value as? String ?? "").isEmpty)
}
```

#### UI-016 — 左滑歷史項，顯示Delete按鈕；點擊後項目消失

```swift
func test_sidebar_swipeToDelete_removesItem() {
    seedHistory(count: 1)
    openMainWindow()
    let cell = app.cells["HistoryCell"].firstMatch
    cell.swipeLeft()
    XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 2))
    app.buttons["Delete"].click()
    XCTAssertFalse(cell.exists)
}
```

### 3.7 Menu Bar Icon三態切換

#### UI-017 — Idle時：menu bar icon顯示mic.fill

**類型：** Manual補充（XCUITest無法直接查menu bar icon SF Symbol名稱）

**步驟：**
1. 確保無active錄音或轉寫。
2. 觀察menu bar icon。
**期望：** 顯示`mic.fill`靜態icon，無動畫。

#### UI-018 — 錄音中：menu bar icon顯示pulse動畫

**類型：** Manual補充

**步驟：**
1. 點擊Record開始錄音。
2. 觀察menu bar icon。
**期望：** 顯示`mic.fill` + pulse動畫。

#### UI-019 — 轉寫中：menu bar icon顯示waveform + pulse

**類型：** Manual補充

**步驟：**
1. 進入轉寫中狀態。
2. 觀察menu bar icon。
**期望：** 顯示`waveform` + pulse動畫。

---

## 4. Edge Case Tests

### 4.1 錄音中關閉window（背景繼續錄音）

#### EC-001 — 錄音中關閉main window，錄音進程不中斷

```swift
func test_edgeCase_closeWindowDuringRecording_recordingContinues() async throws {
    let recorder = MockAudioRecorderService()
    let controller = AppWindowController(recorder: recorder)
    controller.openMainWindow()
    recorder.startRecording()
    XCTAssertEqual(recorder.state, .recording)

    controller.closeMainWindow()

    // 短暫等待
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(recorder.state, .recording, "Recording must continue after window close")
}
```

#### EC-002 — 重開window後，恢復至錄音中畫面（非idle）

```swift
func test_edgeCase_reopenWindowDuringRecording_showsRecordingScreen() {
    // Arrange: 已在背景錄音
    let controller = AppWindowController(recorder: activeRecorderStub())
    controller.openMainWindow()
    controller.closeMainWindow()

    // Act
    controller.openMainWindow()

    let app = XCUIApplication()
    XCTAssertTrue(app.buttons["Stop Recording"].waitForExistence(timeout: 2))
}
```

### 4.2 轉寫中Cancel

#### EC-003 — Cancel後partial results不寫入history

```swift
func test_edgeCase_cancelTranscription_noHistoryEntry() async throws {
    let history = TranscriptionHistory()
    let sut = TranscriptionService(history: history)
    let task = Task {
        try? await sut.transcribeLong(audioPath: mockURL, language: "en") { _ in }
    }
    task.cancel()
    _ = await task.result
    XCTAssertEqual(history.count, 0)
}
```

#### EC-004 — Cancel後m4a臨時文件刪除（錄音模式）

```swift
func test_edgeCase_cancelRecordingTranscription_m4aDeleted() async throws {
    let tempM4A = URL(fileURLWithPath: NSTemporaryDirectory() + "cancel_\(UUID()).m4a")
    try TestAudioFixture.createSilentM4A(at: tempM4A, durationSec: 3)
    let sut = TranscriptionService()
    let task = Task {
        try? await sut.transcribeLong(audioPath: tempM4A, language: "en") { _ in }
    }
    task.cancel()
    _ = await task.result
    XCTAssertFalse(FileManager.default.fileExists(atPath: tempM4A.path))
}
```

### 4.3 磁盤空間不足

#### EC-005 — 可用空間 < 1GB，點擊Record顯示錯誤inline

```swift
func test_edgeCase_diskUnder1GB_recordButtonShowsError() {
    let app = XCUIApplication()
    app.launchEnvironment["MOCK_FREE_DISK_BYTES"] = String(900 * 1024 * 1024)
    openMainWindow(app: app)
    app.buttons["Record Audio"].click()
    XCTAssertTrue(
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Not enough disk space'")).firstMatch
            .waitForExistence(timeout: 2)
    )
}
```

#### EC-006 — m4a總量達1.6GB（80% cap），錄音中顯示橙色警告

```swift
func test_edgeCase_m4aAt80PercentCap_showsWarningDuringRecording() {
    let app = XCUIApplication()
    app.launchEnvironment["MOCK_M4A_USAGE_BYTES"] = String(1_600 * 1024 * 1024)
    startRecordingInUI(app: app)
    let warning = app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS 'MB free'")
    ).firstMatch
    XCTAssertTrue(warning.waitForExistence(timeout: 3))
}
```

### 4.4 不支持格式

#### EC-007 — 上傳.wav，顯示「Unsupported format」錯誤，3秒後fade

```swift
func test_edgeCase_uploadWav_showsFormatError() {
    openMainWindow()
    app.windows["Audio Transcription"].dragAndDrop(from: TestAudioFixture.wavURL)
    let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Unsupported format'")).firstMatch
    XCTAssertTrue(error.waitForExistence(timeout: 2))
    // 3秒後應消失
    XCTAssertFalse(error.waitForExistence(timeout: 4))
}
```

### 4.5 超時長文件（> 2小時）

#### EC-008 — 上傳2hr1s文件，顯示duration exceeded錯誤

```swift
func test_edgeCase_upload2hrPlus_showsDurationError() {
    let longFileURL = TestAudioFixture.dummyURL(duration: 7201)
    openMainWindow()
    app.windows["Audio Transcription"].dragAndDrop(from: longFileURL)
    XCTAssertTrue(
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'exceeds 2-hour limit'")).firstMatch
            .waitForExistence(timeout: 2)
    )
}
```

#### EC-009 — 恰好2小時文件通過驗證（邊界值）

```swift
func test_edgeCase_upload2hrExact_passes() throws {
    let twoHrURL = TestAudioFixture.dummyURL(duration: 7200)
    let validator = AudioFileValidator()
    XCTAssertNoThrow(try validator.validate(url: twoHrURL))
}
```

### 4.6 孤兒m4a清理

#### EC-010 — App啟動時，無對應history entry的m4a自動刪除

```swift
func test_edgeCase_orphanM4A_deletedOnLaunch() throws {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur")
    let orphan = appSupport.appendingPathComponent("orphan_\(UUID()).m4a")
    try TestAudioFixture.createSilentM4A(at: orphan, durationSec: 1)

    // 無對應history entry
    let history = TranscriptionHistory()  // 空白history
    let cleaner = OrphanM4ACleaner(history: history, directory: appSupport)
    cleaner.cleanOnLaunch()

    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
}
```

#### EC-011 — 有對應history entry之m4a（failed狀態）不被刪除

```swift
func test_edgeCase_failedM4AWithHistoryEntry_preserved() throws {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur")
    let failedM4A = appSupport.appendingPathComponent("failed_\(UUID()).m4a")
    try TestAudioFixture.createSilentM4A(at: failedM4A, durationSec: 1)

    var history = TranscriptionHistory()
    history.add(TranscriptionEntry.fixture(m4aPath: failedM4A.path, status: .failed))
    let cleaner = OrphanM4ACleaner(history: history, directory: appSupport)
    cleaner.cleanOnLaunch()

    XCTAssertTrue(FileManager.default.fileExists(atPath: failedM4A.path))
    try? FileManager.default.removeItem(at: failedM4A)
}
```

### 4.7 並發轉寫（排隊/拒絕）

#### EC-012 — 轉寫進行中，嘗試啟動第二個轉寫，被拒絕

```swift
func test_edgeCase_concurrentTranscription_secondRequestRejected() async throws {
    let sut = TranscriptionService(processFactory: MockPythonProcess.slowSuccess())
    let firstTask = Task {
        try await sut.transcribeLong(audioPath: mockURL, language: "en") { _ in }
    }
    try await Task.sleep(nanoseconds: 100_000_000) // 等第一個開始

    do {
        _ = try await sut.transcribeLong(audioPath: mockURL2, language: "en") { _ in }
        XCTFail("Expected queueFullError")
    } catch let err as TranscriptionError {
        XCTAssertEqual(err.kind, .alreadyInProgress)
    }
    firstTask.cancel()
}
```

#### EC-013 — 轉寫進行中，Upload確認頁Start Transcription按鈕禁用

```swift
func test_edgeCase_transcriptionInProgress_uploadStartButtonDisabled() {
    simulateTranscriptionInProgress()
    navigateToUploadConfirmScreen()
    XCTAssertFalse(app.buttons["Start Transcription"].isEnabled)
}
```

### 4.8 轉寫失敗（Python crash / timeout）

#### EC-014 — Python process非正常退出，history記錄狀態為Failed，保留m4a

```swift
func test_edgeCase_pythonProcessCrash_historyEntryIsFailed_m4aRetained() async throws {
    let tempM4A = URL(fileURLWithPath: NSTemporaryDirectory() + "crash_\(UUID()).m4a")
    try TestAudioFixture.createSilentM4A(at: tempM4A, durationSec: 3)
    let history = TranscriptionHistory()
    let sut = TranscriptionService(
        processFactory: MockPythonProcess.crashingProcess(),
        history: history
    )

    _ = try? await sut.transcribeLong(audioPath: tempM4A, language: "en") { _ in }

    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history.allEntries().first?.status, .failed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempM4A.path),
                  "m4a must be retained for retry on failure")
    try? FileManager.default.removeItem(at: tempM4A)
}
```

---

## 5. Manual Test Plans

以下測試需人工執行，原因已逐條說明。

---

### MT-001 — Menu Bar Icon三態切換視覺確認

**原因不自動化：** XCUITest無法查詢NSStatusItem之SF Symbol名稱及symbolEffect動畫狀態。

**Preconditions：** App已啟動，無active session。

**Steps：**
1. 觀察menu bar icon。 → **Expected：** `mic.fill`，無動畫。
2. 點擊Record開始錄音。 → **Expected：** Icon切為`mic.fill` + pulse動畫（約1Hz頻率）。
3. Stop Recording，Start Transcription。 → **Expected：** Icon切為`waveform` + pulse動畫。
4. 等待轉寫完成。 → **Expected：** Icon回到`mic.fill`靜態。

**Priority：** High

---

### MT-002 — activationPolicy切換——Cmd+Tab行為

**原因不自動化：** XCUITest無法操作Cmd+Tab切換器（屬macOS系統層）。

**Preconditions：** App已啟動（accessory mode），無main window。

**Steps：**
1. 按Cmd+Tab。 → **Expected：** Input(Murmur)不出現於切換器。
2. 按Cmd+Shift+T開啟main window。 → **Expected：** Dock顯示app icon。
3. 按Cmd+Tab。 → **Expected：** Input出現於切換器。
4. 關閉main window。 → **Expected：** Dock icon消失，Cmd+Tab不再顯示Input。

**Priority：** High

---

### MT-003 — App Nap / 螢幕鎖定不中斷錄音

**原因不自動化：** 需人工模擬螢幕鎖定（Ctrl+Cmd+Q）；自動化測試環境無鎖定概念。

**Preconditions：** 已開始錄音（5分鐘以上）。

**Steps：**
1. 開始錄音，計時器計數。
2. 按Ctrl+Cmd+Q鎖定螢幕，等待30秒。 → **Expected：** 解鎖後計時器繼續正確計數（未重置）。
3. 解鎖，點擊Stop。 → **Expected：** 確認頁顯示正確duration（≥30s）。
4. Start Transcription。 → **Expected：** 轉寫正常完成，m4a未損壞。

**Priority：** High

---

### MT-004 — Voice Input hotkey在轉寫中首次觸發顯示pill提示

**原因不自動化：** Floating pill屬獨立NSWindow，XCUITest hierarchy難以可靠捕捉其動畫出現/消失；
且「僅首次顯示」之session狀態難在自動化中精確重現。

**Preconditions：** 已進入轉寫中狀態。

**Steps：**
1. 按Voice Input全局快捷鍵。 → **Expected：** Floating pill顯示「Voice input paused」，持續1.5秒後消失。
2. 再按同一快捷鍵。 → **Expected：** Pill不再出現（本session不重複提示）。

**Priority：** Medium

---

### MT-005 — 轉寫進行中關閉main window，通知點擊恢復

**原因不自動化：** macOS通知中心之用戶互動難以在XCUITest中可靠觸發。

**Preconditions：** 已進入轉寫中狀態。

**Steps：**
1. 點擊紅色close button關閉main window。 → **Expected：** 轉寫繼續（menu bar icon仍為waveform+pulse）。
2. 等待轉寫完成，macOS通知出現。 → **Expected：** 通知顯示「Transcription complete」。
3. 點擊通知。 → **Expected：** Main window開啟，直接導航至結果頁。

**Priority：** Medium

---

## 6. Python Unit Test Mirror確認清單

下列Python tests（`Murmur/Scripts/test_chunked_transcribe.py` Layer 1）須在CI全通過，
且Swift ChunkBoundaryTests（UT-007至UT-011）之預期值須與Python test數值一致。

| Python Test | Swift Mirror | 預期值對齊點 |
|-------------|--------------|-------------|
| `test_chunk_boundaries_exact_division` | UT-007 | chunk count = 2，boundary[0].end = 480_000 |
| `test_chunk_boundaries_remainder` | UT-008 | last.end = total_samples |
| `test_chunk_boundaries_short_audio` | UT-009 | count = 1 |
| `test_overlap_exceeds_chunk` | UT-010 | throws ChunkError.overlapExceedsChunk |
| `test_zero_length_audio` | UT-011 | throws ChunkError.emptyAudio |

---

## 7. 測試覆蓋缺口與建議

| 缺口 | 優先級 | 建議 |
|------|--------|------|
| 中文CER準確度（Phase 1補） | P1 | 建立ZH測試集；AISHELL數據集。目標CER < 10% |
| 中文overlap trimming | P1 | character-based trimming實現後補充UT |
| m4a錄音中2小時自動停止 | P2 | 需Mock clock加速時間，或縮短cap用於測試 |
| AVFoundation vs ffmpeg decode路徑選擇 | P1 | EN確認後補IT；需測試方案C (AVFoundation)成功路徑及fallback |
| 磁盤空間每30秒輪詢邏輯 | P2 | 需Mock clock/timer；補UT |
| Retry失敗項（保留m4a重新轉寫） | P1 | 補UI-020；EC-014已覆蓋unit側 |
| 超長文字（>100KB）之TextEditor性能 | P2 | 手動壓測；非功能需求 |

---

*@QA — 2026-04-10*
