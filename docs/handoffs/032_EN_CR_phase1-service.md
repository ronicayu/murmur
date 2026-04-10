---
id: "032"
from: EN
to: CR
status: RDY
date: 2026-04-10
topic: Phase 1 Step 1 — TranscriptionService long-audio extension
---

## 摘要

Phase 1 Step 1 完成。`TranscriptionService` 已擴展支持長音頻分塊轉寫。新增11個測試，全數通過；既有54個測試無退化。

## 所做之事

### 新增類型

**`TranscriptionProgress: Sendable`**（`TranscriptionService.swift`）
- 字段：`currentChunk: Int`、`totalChunks: Int`、`partialText: String`
- 對應 Python progress event JSON

**`JSONLineParser`**（`TranscriptionService.swift`）
- 獨立 struct，讀取 Pipe 直至 `type=result` 到達
- 每遇 `type=progress` 行即調用 `onProgress`
- 遇 `error` 字段或 premature EOF 拋出 `MurmurError.transcriptionFailed`
- 提取為獨立值類型以利單元測試（不依賴真實 Python 進程）

### 協議更新

`TranscriptionServiceProtocol` 新增：
```swift
func transcribeLong(
    audioURL: URL,
    language: String,
    onProgress: @escaping (TranscriptionProgress) -> Void
) async throws -> TranscriptionResult
```

### `TranscriptionService` actor 擴展

`transcribeLong()` 方法：
- 守衛 `_isLongRunning` 旗標（max-1 並發）
- 必要時自動調用 `preloadModel()`
- 發送 `{"cmd":"transcribe_long","audio_path":"...","language":"...","chunk_sec":30,"overlap_sec":5}` 命令
- 委托 `JSONLineParser.readUntilResult()` 讀取多行回應
- 支持 Swift Task 取消（`withTaskCancellationHandler` → `killProcessFromOutside()`）
- 不破壞既有 `transcribe()` 方法

### `AppCoordinator` 擴展

新增 `transcribeLong(audioURL:onProgress:)` 公開方法：
- 進入 `.transcribing` 態（自動抑制 hotkey）
- 注入完成後走既有 `.injecting → .undoable → .idle` 流程
- 取消時靜默回到 `.idle`
- 持有 `longTranscribeTask: Task<Void, Never>?`，`stop()` 時一併取消

## 測試覆蓋（新增11個）

| 測試類 | 測試數 | 覆蓋點 |
|--------|--------|--------|
| `TranscriptionProgressSendableTests` | 2 | Sendable 跨 actor、字段正確性 |
| `TranscriptionServiceProtocolLongTests` | 1 | Protocol 形狀（編譯時驗證） |
| `SendLongParsingTests` | 6 | Progress 回調計數、result 解析、error 拋出、premature EOF、中文語言、無 progress 直達 result |
| `TranscriptionLongConcurrencyTests` | 2 | 并發第二呼叫拒絕、完成後閘門釋放 |

## 設計決策

1. **`JSONLineParser` 獨立**：從 actor 中提取解析邏輯為值類型，使其可用 `PipeSimulator` 做純 Swift 單元測試，無需 Python 進程。actor 本體僅持有 subprocess 狀態。

2. **`_isLongRunning` 旗標於 actor 內**：actor 隔離保證原子性，無需額外鎖。仍允許短音頻 `transcribe()` 並發（二者使用同一 subprocess，但 Python 端串行處理，Swift 端 actor 已保護）。

3. **取消語意**：Task 取消 → `killProcessFromOutside()` → Python 進程終止 → `availableData` 返回空 → `JSONLineParser` 拋出 EOF 錯誤 → `withTaskCancellationHandler` 捕捉。進程在下次呼叫時由 `ensureProcessRunning()` 重啟。

4. **Pause/Resume 語意**：`AppCoordinator.transcribeLong()` 進入 `.transcribing` 態後，`handleHotkeyEvent` 中的 `state == .transcribing → pendingRecording = true` 邏輯自然抑制新錄音，完成後回到 `.idle` 解除。無需額外 pause/resume 機制。

## 待審核重點

- `JSONLineParser` 中 `buffer` 的邊界處理（行拆分邏輯）
- `transcribeLong` 未清理 `audioURL` 臨時文件（`transcribe()` 有清理，long 版本沒有，因為文件是外部傳入的，不一定是臨時文件）
- `AppCoordinator.transcribeLong()` 中無 timeout 包裝（長音頻本就耗時不定，故意省略）

## 相關文件

- `/Users/ronica/projects/input/Murmur/Services/TranscriptionService.swift`
- `/Users/ronica/projects/input/Murmur/AppCoordinator.swift`
- `/Users/ronica/projects/input/Murmur/Tests/TranscriptionServiceLongTests.swift`
