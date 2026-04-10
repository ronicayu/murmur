# Handoff 053 — EN → CR / DA: V3 Phase 1 CR+DA Fixes

**From:** EN
**To:** CR, DA
**Status:** RDY
**Date:** 2026-04-10
**Re:** V3 Streaming Voice Input — CR 051 + DA 052 全部 issues 修復

---

## 結果摘要

170 tests，0 failures，7 skipped（AX permission — 與前次相同，非本次修改影響）。

---

## CR fixes

### CR-P0-1: Chunk temp WAV leak ✓

**File:** `Services/StreamingTranscriptionCoordinator.swift`

`processChunkBuffer` 之 `Task.detached` 中，成功路徑及失敗路徑各加：

```swift
try? FileManager.default.removeItem(at: chunkURL)
```

成功路徑於 `handleChunkTranscription` 前清除；失敗路徑於 log warning 前清除。`self == nil` 路徑早已有清除，保持不變。

---

### CR-P1-1: InjectedRangeTracker 單位改 UTF-16 ✓

**File:** `Services/StreamingTranscriptionCoordinator.swift`

`handleChunkTranscription` 改：

```swift
self.rangeTracker?.recordInjection(length: textToInject.utf16.count)
```

`InjectedRangeTracker` struct doc comment 明確標注「所有 offset 及 length 均為 UTF-16 code units，以匹配 kAXSelectedTextRangeAttribute」。

---

### CR-P1-2: replaceRange fallback 重複注入 ✓

**File:** `Services/TextInjectionService.swift`

AX replace 失敗時，移除 `_ = try await inject(text: text)` fallback，改為：

```swift
log.warning("replaceRange: AX replace unavailable — skipping replacement, streaming version preserved")
```

不拋出，讓 coordinator 繼續至 `.done`。streaming 版本保留。

---

### CR-P2-1: CPULoadMonitor.stop() 加 @MainActor ✓

**File:** `Services/StreamingTranscriptionCoordinator.swift`

```swift
@MainActor
func stop() { ... }
```

因 `highLoadStart` 僅在 `@MainActor evaluate()` 中讀寫，此標注消除靜態並發驗證盲區。

測試中 `monitor.stop()` 呼叫點更新為 `await MainActor.run { monitor.stop() }`。

---

### CR-P2-2: waitForStreamingDone() 改 Combine 訂閱 ✓

**File:** `AppCoordinator.swift`

移除 100ms polling loop，改用 `AsyncStream` 訂閱 `@Published sessionState`：

```swift
let stream = AsyncStream<StreamingSessionState> { continuation in
    let cancellable = coordinator.$sessionState.sink { state in
        continuation.yield(state)
    }
    continuation.onTermination = { _ in cancellable.cancel() }
}
for await state in stream { ... }
```

加 `import Combine`。

---

## DA fixes

### DA-P0-1: replaceRange 在 Electron app 不可靠 ✓

**File:** `Services/TextInjectionService.swift`

加 `isFrontmostAppIncompatibleWithAXReplace()` 方法，對已知不支持 AX range replace 的 app（VS Code、Obsidian、Slack、Discord、Figma 等 Electron-based apps）於 `replaceRange` 入口早返回，並 log warning。

已知 bundle ID prefix 清單：
- `com.microsoft.VSCode`
- `md.obsidian`
- `com.todesktop.` （Electron app-builder 前綴）
- `com.github.GitHubDesktop`
- `com.figma.desktop`
- `com.slack.Slack`
- `com.tinyspeck.slackmacgap`
- `com.discord`

此清單為 best-effort；Phase 2 可補充 spike #4 實測結果後擴充。

---

### DA-P0-2: InjectedRangeTracker 游標假設 ✓

**File:** `Services/StreamingTranscriptionCoordinator.swift`

`InjectedRangeTracker` 新增：
- `expectedNextOffset: Int` — 計算 `startOffset + totalLength`
- `invalidated: Bool` — 游標偏移時置 true
- `mutating func invalidate()`

`handleChunkTranscription` 中，每次 appendText 前查詢 AX 當前游標：

```swift
if let expectedNext = self.rangeTracker?.expectedNextOffset {
    let actualOffset = self.resolveCurrentCursorOffsetAX()
    if actualOffset != nil && actualOffset != expectedNext {
        self.rangeTracker?.invalidate()
        // log warning
    }
}
```

`runFullPass` 中，若 `tracker.invalidated == true` 則跳過替換，保留 streaming 版本（spec §5 rule 3）。

新增 `resolveCurrentCursorOffsetAX()` private helper（與 `AppCoordinator.resolveCurrentCursorOffset()` 相同邏輯，提取至 coordinator 內部）。

新增 test hook `simulateTrackerInvalidation()` 供 integration test 使用。

---

### DA-P1-3: Focus guard race condition ✓

**File:** `Services/StreamingTranscriptionCoordinator.swift`

新增 `private var focusAbandonTask: Task<Void, Never>?`。

`handleFocusEvent(.focusLeft)` 中：

```swift
focusAbandonTask?.cancel()
focusAbandonTask = Task { @MainActor [weak self] in
    guard let self else { return }
    try? await Task.sleep(for: .seconds(Self.focusAbandonSeconds))
    guard !Task.isCancelled else { return }
    guard self.isFocusPaused, case .streaming = self.sessionState else { return }
    self.cancelSession()
}
```

`handleFocusEvent(.focusReturned)` 中先 cancel task、再清 `isFocusPaused`，消除競態。

`cancelSession()` 亦清 `focusAbandonTask`。

---

### DA-P1-4: Chunk WAV 未清理 ✓

同 CR-P0-1，已修。

---

### DA-P1-5: Full-pass 等待無進度 ✓

**Files:** `Services/StreamingTranscriptionCoordinator.swift`, `AppCoordinator.swift`

coordinator 新增：
- `private(set) var finalizingStartedAt: Date?` — `endSession()` 時設置
- `static let fullPassWarningSeconds: TimeInterval = 15.0`
- `static let fullPassTimeoutSeconds: TimeInterval = 30.0`

`runFullPass` 改用 `withTaskGroup` 競賽模式（transcription vs. timeout），30s 超時後 log warning，`transition(to: .done)` 保留 streaming 版本。

`waitForStreamingDone` 中，於 `.finalizing` 狀態檢查 `finalizingStartedAt`，超過 15s 時 log warning（pill 可據此顯示「Still refining」提示）；超過 30s 時 `cancelSession()`。

**注：** pill UI 之「Refining...」文字顯示未在本次修改範疇（需 UX / FloatingPillView 配合）。coordinator 側已暴露 `finalizingStartedAt` 供 pill 計算用時。

---

### DA-P2: Integration tests ✓

**File:** `Tests/V3Phase1Tests.swift`

新增 `StreamingPipelineIntegrationTests`（2 tests）：

**9a — `test_pipeline_twoChunkSession_fullPassReplaces_whenTextDiffers`**

- 模擬 2 chunk session（feed 6s 音頻）
- chunk transcriptions 返回 "hello wurld" / "how are you"
- full-pass 返回 "hello world how are you"（更正）
- 驗證 coordinator 達到 `.done`，`replaceRangeCalls` 非空且內容正確

**9b — `test_pipeline_trackerInvalidated_skipsFullPassReplacement`**

- 模擬 1 chunk session
- 透過 `simulateTrackerInvalidation()` 模擬游標移動
- 驗證 `replaceRangeCalls` 為空（tracker invalidated → 跳過替換）

`MockTranscriptionService` 新增 `onTranscribe: ((URL) throws -> TranscriptionResult)?` per-call handler，供 integration test 依序返回不同結果。

---

## 未修 / 已知剩餘事項

| 項目 | 原因 | 建議後續 |
|------|------|---------|
| DA-P1-5 pill「Refining...」文字 | 需 FloatingPillView 配合，超出 EN 範疇 | UX 接手，coordinator `finalizingStartedAt` 已暴露 |
| DA-P0-1 Electron app 清單完整性 | spike #4 仍未執行 | QA/UT 在 5 target apps 實測後補充 bundle ID |
| DA-P1-3 10s timeout 使否可調 | 本次保留 10s hardcode | Phase 2 Settings 可加 slider |

---

## 修改檔案清單

- `Murmur/Services/StreamingTranscriptionCoordinator.swift`
- `Murmur/Services/TextInjectionService.swift`
- `Murmur/AppCoordinator.swift`
- `Murmur/Tests/V3Phase1Tests.swift`

---

## in

- `docs/handoffs/051_CR_EN_v3-review.md`
- `docs/handoffs/052_DA_EN_v3-challenge.md`
- `Murmur/Services/StreamingTranscriptionCoordinator.swift`
- `Murmur/Services/TextInjectionService.swift`
- `Murmur/AppCoordinator.swift`
- `Murmur/Tests/V3Phase1Tests.swift`

## out

`docs/handoffs/053_EN_CR_DA_v3-fixes.md` — 全部 CR+DA issues 已修，170 tests pass。
