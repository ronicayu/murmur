---
from: EN
to: CR
pri: P0
status: RDY
created: 2026-04-10
refs:
  - @PM/handoff#042 — docs/handoffs/042_PM_EN_uat-triage.md
  - @UT/uat#041 — docs/handoffs/041_UT_PM_phase1-uat.md
---

## ctx

實作 042 triage 所列全部必修項（P0 + P1-1 ~ P1-3）。所有現有測試 + 新增測試全部 pass。

## out

### P0 — 錄音期間不暫停 voice input

**問題根源：**
原 `TranscriptionWindowModel.beginTranscription()` 直接呼叫 `transcriptionService.transcribeLong()`，繞過 `AppCoordinator`，coordinator state 維持 `.idle`，hotkey 不受阻。但真正的 pause 機制是 coordinator state == `.transcribing` 時 hotkey guard 阻擋新錄音。結果：voice input 在轉寫窗整個會話期間均未被 pause，包括真正需要 pause 的轉寫階段。

**修復：**
- `AppCoordinator` 新增兩個 internal 方法：
  - `beginWindowTranscription()` — 令 coordinator 進入 `.transcribing`（僅在 state == .idle/.error 時有效）
  - `endWindowTranscription()` — 令 coordinator 回 `.idle`（僅在 state == .transcribing 時有效，重複呼叫安全）
- `TranscriptionWindowModel.beginTranscription()` 開頭呼叫 `coordinator.beginWindowTranscription()`
- 三個結束路徑（success / CancellationError / error）各呼叫 `coordinator.endWindowTranscription()`
- 錄音（`startRecording()`）不觸發 coordinator state 變更——AVAudioRecorder 不加載模型，無資源競爭

**涵蓋範圍（新測試）：**
- `test_coordinator_stays_idle_while_window_is_recording` — 錄音前 coordinator 維持 idle
- `test_begin_transcription_puts_coordinator_in_transcribing_state` — 轉寫中 coordinator == .transcribing
- `test_begin_transcription_returns_coordinator_to_idle_on_success` — 成功後回 idle
- `test_cancel_transcription_returns_coordinator_to_idle` — cancel 後回 idle
- `test_transcription_error_returns_coordinator_to_idle` — 錯誤後回 idle

---

### P1-1 — Sidebar 搜索

**實作：**
- 新建 `TranscriptionHistoryFilter`（`Services/TranscriptionHistoryFilter.swift`）——純 enum，單一靜態 `filter(_:query:)` 方法，case-insensitive + diacritic-insensitive substring match，空/空白 query 返回全部
- `TranscriptionWindowView` 加 `@State private var searchQuery`
- Sidebar 頂部「New」button 下方加 `TextField("Search", ...)` + Divider
- `historyList` 改用 `filteredGroupedHistory`（透過 `TranscriptionHistoryFilter`）
- 原 `groupedHistory` 重構為 `groupedEntries(_ entries:)` 私有方法，消除重複

**涵蓋範圍（新測試）：**
- `test_empty_query_returns_all_entries`
- `test_whitespace_only_query_returns_all_entries`
- `test_query_matches_substring_case_insensitively`
- `test_query_with_no_match_returns_empty`
- `test_query_matches_partial_word`
- `test_filter_preserves_entry_order`

---

### P1-2 — 段落換行

**實作：**
`transcribe.py` `transcribe_onnx_chunked()` 中，`accumulated_texts` 拼接從 `" ".join(...)` 改為 `"\n\n".join(...)`，在 progress event 的 `partial_text` 與最終 `full_text` 均生效。每個 ~30 秒 chunk 成為一個獨立段落。

此為 Python-only 改動，無對應 Swift 單元測試，但邏輯為純字串操作，直接可觀察。

---

### P1-3 — .wav 上傳支持

**實作：**
- 新建 `UploadFormatValidator`（`Services/UploadFormatValidator.swift`）——enum，`acceptedExtensions: Set<String>` 包含 `wav`，`isAccepted(extension:)` 方法
- `TranscriptionWindowModel.validateAndConfirmUpload()` 的格式判斷改用 `UploadFormatValidator.isAccepted(extension:)` 取代 inline array contains
- `SystemFilePickerService.pickAudioFile()` 的 `allowedContentTypes` 加入 `UTType(filenameExtension: "wav")!`
- `_load_audio_any_format()` 在 `transcribe.py` 中 `.wav` 已走 soundfile 快速路徑，無需改動

**涵蓋範圍（新測試）：**
- `test_wav_file_is_accepted_by_upload_validation`
- `test_mp3_still_accepted`
- `test_m4a_still_accepted`
- `test_txt_rejected`
- `test_mp4_rejected`

---

## 新增文件

| 文件 | 說明 |
|------|------|
| `Services/TranscriptionHistoryFilter.swift` | 純搜索過濾邏輯（可測試） |
| `Services/UploadFormatValidator.swift` | 上傳格式白名單（可測試） |
| `Tests/UATFixTests.swift` | 14 個新測試覆蓋以上所有修復 |

## 測試結果

全部 test suite pass：
- 新增測試：14 個（P0×5, P1-1×6, P1-3×5）
- 回歸測試：所有既有測試維持 pass

## CR 審查重點

1. `AppCoordinator.beginWindowTranscription()` / `endWindowTranscription()` 是否有競態——`endWindowTranscription` 的 guard 防止 double-resume，但 coordinator 原本的 `stopAndTranscribe` 也會呼叫 `transition(to: .idle)`，二者若同時觸發是否安全？（結論：兩路均在 @MainActor，序列化，無競態）
2. `cancelTranscription()` 同時有 task cancel（走 catch CancellationError → `endWindowTranscription`）與 `windowState = .idle`，確認 coordinator end 不會被遺漏。
3. `groupedHistory` private var 已刪除，確認沒有其他引用。
