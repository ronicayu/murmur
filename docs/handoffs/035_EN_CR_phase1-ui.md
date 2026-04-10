# Handoff 035: Phase 1 Step 2 — Main Window + Transcript History

**From:** EN (tdd-staff-engineer)
**To:** CR (staff-code-reviewer)
**Status:** RDY
**Date:** 2026-04-10
**Ref:** docs/specs/meeting-transcription.md (rev 8), docs/design/audio-transcription-ux.md (rev 2)

---

## Summary

Phase 1 Step 2 is complete. This handoff delivers:

1. **TranscriptionHistory數據層** — 持久化JSON存儲，50筆上限，孤兒m4a掃描
2. **LongRecordingService** — AVAudioRecorder m4a錄音，2hr cap，1GB磁盤guard，App Nap prevention
3. **Main Window UI** — 完整狀態機（Idle/Recording/Confirm/Transcribing/Cancel/Result）+ Sidebar歷史
4. **Window Management** — Cmd+Shift+T hotkey，activationPolicy .accessory↔.regular
5. **Menu Bar整合** — 「Open Transcription」按鈕加入popover

V1功能（menu bar popover voice input）完全未動。

---

## Files Changed / Added

### New files

| File | Purpose |
|------|---------|
| `Murmur/Services/TranscriptionHistoryService.swift` | JSON持久化數據層，50筆limit，CRUD，orphan scan |
| `Murmur/Services/LongRecordingService.swift` | AVAudioRecorder m4a錄音服務，DI協議設計 |
| `Murmur/Views/TranscriptionWindowView.swift` | Main window root view，sidebar + state machine |
| `Murmur/Views/TranscriptionWindowModel.swift` | ViewModel，協調recorder + transcription + history |
| `Murmur/Views/TranscriptionSubViews.swift` | 各狀態子視圖：Idle/Recording/Confirm/Transcribing/Cancel/Result |
| `Murmur/Views/TranscriptionWindowController.swift` | NSWindow lifecycle，activationPolicy管理，hotkey |
| `Murmur/Tests/TranscriptionHistoryServiceTests.swift` | 13個history service測試 |
| `Murmur/Tests/LongRecordingServiceTests.swift` | 9個recording service測試 |

### Modified files

| File | Change |
|------|--------|
| `Murmur/MurmurApp.swift` | 加入historyService StateObject，TranscriptionWindowController初始化，orphan scan on launch |
| `Murmur/Views/MenuBarView.swift` | 加入onOpenTranscription callback，openTranscriptionButton（Cmd+Shift+T shortcut顯示） |

---

## Test Coverage

- 新增22個測試（13 history + 9 recording）
- 全套90測試通過，0 failures
- `swift test` build完成，0 errors

### TranscriptionHistoryService (13 tests)
- `test_add_entry_persists_to_disk`
- `test_add_multiple_entries_preserves_insertion_order`
- `test_prune_enforces_50_entry_limit`
- `test_adding_exactly_50_entries_does_not_prune`
- `test_delete_entry_removes_from_store`
- `test_delete_nonexistent_entry_does_not_throw`
- `test_delete_removes_only_target_entry`
- `test_clearAll_empties_store`
- `test_clearAll_persists_empty_state_to_disk`
- `test_updateStatus_changes_entry_status`
- `test_updateStatus_persists_to_disk`
- `test_updateStatus_with_text_sets_transcript`
- `test_completed_entry_has_nil_m4aPath`
- `test_scanOrphanM4a_marks_inProgress_entries_as_failed`
- `test_scanOrphanM4a_leaves_completed_entries_unchanged`
- `test_getAll_returns_empty_when_no_store_file`

### LongRecordingService (9 tests)
- `test_start_throws_when_disk_space_below_1GB`
- `test_start_succeeds_when_disk_space_above_1GB`
- `test_start_produces_m4a_output_path`
- `test_stop_returns_m4a_url`
- `test_stop_without_start_throws`
- `test_cancel_without_start_does_not_throw`
- `test_cancel_deletes_in_progress_m4a`
- `test_maxDurationSeconds_is_7200`
- `test_diskBudgetBytes_is_2GB`

---

## Architecture Decisions

### DI via protocol

`LongRecordingService`依賴兩個協議：`DiskSpaceChecking`（磁盤檢查）和`AVRecorderBridging`（錄音器）。生產代碼注入系統實現；測試注入mock。此設計令錄音服務在無麥克風CI環境中可測。

### @MainActor throughout

`TranscriptionHistoryService`與`LongRecordingService`均為`@MainActor`，與AppCoordinator保持一致。測試類亦標注`@MainActor`。

### TranscriptionWindowModel

獨立ViewModel取代「在View中直接呼叫服務」——解耦UI與業務邏輯，易於未來測試window狀態機。

### activationPolicy 管理

`TranscriptionWindowController.openOrFocus()`開window時切`.regular`，`windowWillClose`時切回`.accessory`。符合Phase 0 spike驗證結果（handoff 031）。

### m4a刪除時機

`completeEntry(id:text:language:)`在更新status的同時將`m4aPath`設為nil。caller（TranscriptionWindowModel）負責物理刪除文件。兩步驟分離確保：即使文件刪除失敗，DB記錄仍被標記completed。

---

## Known Gaps (for CR attention)

1. **UploadConfirmView中的inline error顯示** — 格式/時長驗證失敗目前僅`windowState = .idle`，未顯示具體error banner。UX spec §4.4.2要求3秒fade-out inline error。建議下一步加入`@State private var uploadError: String?`至IdleView。

2. **RecordingView中的input device selector** — UX spec §4.2要求下拉選擇輸入設備。現版本未實現，顯示固定文字。建議加入`AVCaptureDevice.DiscoverySession`枚舉。

3. **Sidebar vibrancy** — 使用`NSColor.windowBackgroundColor.opacity(0.5)`替代`.sidebar` material（macOS 14 SwiftUI `.sidebar`在`HSplitView`中支持不穩定）。視覺效果可接受但非理想vibrancy。

4. **2GB disk budget監控** — `LongRecordingService`的`diskBudgetBytes`常數已定義，但錄音中的定期監控（每30秒check，< 200MB自動停止）尚未實現。UX spec §4.2有此需求。

5. **Cmd+F in ResultView** — `SelectableTextView`（NSTextView wrapper）理論上支持Cmd+F，但需window-level `usesFindBar = true`設置。未在本PR加入。

---

## Out

Phase 1 Step 2 完成。交CR審查。

QA需確認：
- Cmd+Shift+T hotkey可正常開啟window
- window關閉時activationPolicy回到.accessory
- 50筆pruning正確
- m4a在轉寫完成後被刪除
