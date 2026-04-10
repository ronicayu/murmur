---
id: "039"
from: EN
to: CR
status: RDY
date: 2026-04-10
topic: Phase 1 — all CR/DA fixes applied (P1 + nits + C1–C6)
---

## 摘要

CR #037（P1 + 3 nits）及 DA #038（C1–C6）所有修復已施行。全套測試通過（原有 + 8 新增），無退化。

---

## CR修復

### P1 — `TranscriptionWindowModel.beginTranscription` catch塊

**文件**：`Murmur/Views/TranscriptionWindowModel.swift`

將 `guard !Task.isCancelled` 改為 `catch is CancellationError`，符合 `AppCoordinator.transcribeLong` 已有模式。CancellationError路徑：刪除 inProgress entry、windowState → idle。普通錯誤路徑：updateStatus → .failed。

### Nit-1 — `groupedHistory` 排序

**文件**：`Murmur/Views/TranscriptionWindowView.swift`

bucket的剩餘鍵改為以該bucket最新 entry.date 降序排列（`rhsDate > lhsDate`），替代原字母序。Today/Yesterday固定在前。

### Nit-3 — `validateAndConfirmUpload` DI

**文件**：`Murmur/Views/TranscriptionWindowModel.swift`

新增 `diskChecker: DiskSpaceChecking` 參數（預設 `SystemDiskSpaceChecker()`）。`validateAndConfirmUpload` 改用 `diskChecker` 而非直接實例化，與 `LongRecordingService` DI模式一致。

---

## DA修復

### C1 (HIGH) — `transcribe()` guard

**文件**：`Murmur/Services/TranscriptionService.swift`

`transcribe()` 方法首部加入：
```swift
guard !_isLongRunning else {
    throw MurmurError.transcriptionFailed("Long transcription in progress")
}
```
防止 V1 hotkey 在 `transcribeLong` 期間寫入同一 pipe，造成 JSON 協議污染。

### C2 (LOW) — Partial persist

**文件**：`Murmur/Services/TranscriptionHistoryService.swift`、`Murmur/Views/TranscriptionWindowModel.swift`

新增 `TranscriptionHistoryService.persistPartialText(id:partialText:)` — 更新 entry 文字但保持 status=inProgress。`beginTranscription` 的 `onProgress` callback 每 5 個 chunk 呼叫一次，縮小 crash 數據丟失窗口。

C2a（JSON大小）及 C2b（atomic write trade-off）確認為已知且可接受的設計決定：50筆 worst-case ~1MB，原子寫入確保文件完整性，force-quit 丟失最多一次寫入間隔，無需 WAL。

### C3 (MED) — `windowWillClose` 多window

**文件**：`Murmur/Views/TranscriptionWindowController.swift`

`windowWillClose` 改為先檢查是否有其他 visible window：
```swift
let hasOtherVisibleWindow = NSApp.windows.contains { $0 !== closingWindow && $0.isVisible }
guard !hasOtherVisibleWindow else { return }
NSApp.setActivationPolicy(.accessory)
```
若 onboarding 或 settings window 仍開啟，保持 `.regular`，不隱藏 Dock icon。

多Space問題確認為已知 macOS behavior（非可程式修復），留待 UX 說明文字處理。

### C4 (MED) — FilePickerService 提取

**文件**：`Murmur/Views/TranscriptionWindowModel.swift`

新增 `FilePickerService` protocol 及 `SystemFilePickerService` 實作（NSOpenPanel 邏輯移入此處）。`TranscriptionWindowModel` 加入 `filePicker: FilePickerService` 注入點（預設 `SystemFilePickerService()`）。`openFilePicker()` 縮減為一行。

### C5 (MED) — TranscriptionWindowModel 測試

**文件**：`Murmur/Tests/TranscriptionWindowModelTests.swift`（新建）

8個新測試，覆蓋：

| 測試 | 覆蓋場景 |
|------|---------|
| `test_beginTranscription_transitions_to_result_on_success` | happy path → .result |
| `test_beginTranscription_completes_history_entry_on_success` | history entry 標記 completed |
| `test_beginTranscription_on_cancellation_clears_history_and_returns_to_idle` | CancellationError → idle |
| `test_beginTranscription_on_cancellation_does_not_mark_history_failed` | 取消不留 .failed entry |
| `test_beginTranscription_on_error_marks_history_failed_and_returns_to_idle` | 普通錯誤 → .failed + idle |
| `test_cancelTranscription_deletes_active_entry_and_transitions_to_idle` | cancelTranscription() 流程 |
| `test_transcriptionService_rejects_short_transcribe_while_long_running` | C1 guard 行為 |
| `test_validateAndConfirmUpload_uses_injected_disk_checker` | disk checker DI |

新增測試 double：`SpyTranscriptionService`（`@unchecked Sendable` class，可從 @MainActor 設定）、`StubDiskSpaceChecker`。

為支援測試，`TranscriptionWindowModel` 加入 `transcriptionService: (any TranscriptionServiceProtocol)?` 注入點（預設 nil，fallback 至 `coordinator.transcription`）。

### C6 (HIGH/BLOCKER) — 中文 overlap trimming

**文件**：`Murmur/Resources/transcribe.py`

提取 `_is_cjk_dominant(text)` 及 `_trim_overlap(text)` 兩個 inner function：

- `_is_cjk_dominant`：CJK字符 / 全字母字符 > 30% 判定為中文主導。
- `_trim_overlap`（中文路徑）：按字符數 trim，`chars_to_trim = overlap_sec × CHINESE_CHARS_PER_SEC`（預設 4 chars/sec），適用於無空格的中文轉錄輸出。
- `_trim_overlap`（西文路徑）：保留原有 word-based 邏輯。

此修復解除 spec open question #5（Phase 1 強制項）。

---

## 測試結果

```
Test Suite 'All tests' passed
```

新舊合計：`All tests passed`，無退化。

---

## 設計決策記錄

**`injectedTranscriptionService` 非 breaking change**：`TranscriptionWindowModel.init` 新增兩個可選參數（`diskChecker`、`filePicker`、`transcriptionService`），均有預設值，現有呼叫點（`TranscriptionWindowView`）無需修改。

**`SpyTranscriptionService` 用 class 非 actor**：test double 需從 @MainActor 設定屬性；`@unchecked Sendable` + `nonisolated(unsafe)` 是此場景的標準模式（P0FixTests 中 `FakeLongTranscriptionGate` 同理）。

---

## out

- 狀態：RDY
- 下一步：CR 覆核修改；QA 可補充 Python 側 overlap trimming 的 integration test
