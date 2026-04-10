# Handoff 051 — CR → EN: V3 Phase 1 Code Review

**From:** CR
**To:** EN
**Status:** CHG:3
**Date:** 2026-04-10
**Re:** V3 Streaming Voice Input — Phase 1 review

---

## Verdict

**Needs Changes.** 三個必修問題（P0×1、P1×2），兩個應修（P2），其餘LGTM。

---

## P0 — 必修（阻止合併）

### P0-1: chunk temp WAV file leak

**File:** `StreamingTranscriptionCoordinator.swift` L442–457

`processChunkBuffer()` 寫 temp WAV (`chunkURL`) 後，成功轉錄時**未刪除**。只有 `self == nil` 或 `writeBufferToTempWAV` 失敗時才清除。每 3 秒一個 WAV（約 96 KB @ 16 kHz/float32），長錄音持續洩漏。

```swift
// 現狀：成功路徑無清除
let result = try await self.transcription.transcribe(audioURL: chunkURL, language: lang)
await MainActor.run { self.handleChunkTranscription(result.text) }
// chunkURL 永遠留在 /tmp/

// 修正：
do {
    let result = try await self.transcription.transcribe(audioURL: chunkURL, language: lang)
    try? FileManager.default.removeItem(at: chunkURL)   // ← 加此行
    await MainActor.run { self.handleChunkTranscription(result.text) }
} catch {
    try? FileManager.default.removeItem(at: chunkURL)   // ← 失敗路徑亦清除
    await MainActor.run { self.logger.warning(...) }
}
```

---

## P1 — 應修（語義正確性）

### P1-1: InjectedRangeTracker 計數與 AX offset 不一致（CJK + emoji）

**File:** `StreamingTranscriptionCoordinator.swift` L473 / `InjectedRangeTracker` L217

`rangeTracker.recordInjection(length: textToInject.count)` 使用 Swift `String.count`（Unicode scalar 數）。AX `kAXSelectedTextRangeAttribute` 使用 UTF-16 code unit 數。語音輸出若含 emoji（罕見但可能），兩者不同，導致 `replaceRange` 選錯範圍、替換錯位文字。

同樣問題存於 `resolveCurrentCursorOffset()`（AppCoordinator L508）：`cfRange.location + cfRange.length` 取自 AX（UTF-16），傳入 `InjectedRangeTracker(startOffset:)`，再與 `String.count` 累加——單位不一致。

**修正：** 用 `textToInject.utf16.count` 替代 `textToInject.count`，並在 `InjectedRangeTracker` 文件中明確說明單位為 UTF-16 code units。

### P1-2: replaceRange fallback 造成文字重複注入

**File:** `TextInjectionService.swift` L118–120

AX replace 失敗時 fallback 為 `inject(text: text)`（clipboard paste），這會**追加** fullText 至游標位置，而非替換。用戶在不支援 AX 的 app（如 Electron-based 編輯器）中將看到 streaming 文字 + full-pass 文字重複出現。

handoff 050 已標注此為 spike #4 incomplete。本 CR 確認此為 P1：不應靜默降級為重複注入，應改為**不執行替換**並記錄 warning，讓 streaming 版本保持原樣。

```swift
// 現狀：fallback 追加，造成重複
_ = try await inject(text: text)

// 修正：靜默放棄，保留 streaming 版本
log.warning("replaceRange: AX replace unavailable — skipping replace, streaming version preserved")
// 不拋出，讓 coordinator 繼續到 .done
```

---

## P2 — 建議修（品質/可靠性）

### P2-1: CPULoadMonitor.stop() 無 MainActor 隔離

**File:** `StreamingTranscriptionCoordinator.swift` L144–148

`stop()` 未標記 `@MainActor` 但寫入 `highLoadStart`（只在 `@MainActor evaluate()` 讀寫）。目前所有呼叫點（`endSession`、`cancelSession`、`handleCPUFallback`）均在 `@MainActor` 的 `StreamingTranscriptionCoordinator` 內，故實際安全。但 `CPULoadMonitor` 是 `@unchecked Sendable`，Swift 編譯器無法靜態驗證。

```swift
// 修正：加 @MainActor 標記
@MainActor
func stop() { ... }
```

### P2-2: waitForStreamingDone() 使用 polling

**File:** `AppCoordinator.swift` L481–494

每 100ms polling coordinator state，最多等 30s。應改用 `AsyncStream` 或 `Combine` 訂閱 `@Published sessionState`，避免不必要的喚醒。功能正確但實現粗糙，streaming 普及後可改。

---

## LGTM 部分

- **V1 隔離**：確認完全。`startV1RecordingFlow()` / `stopAndTranscribeV1()` 邏輯與舊版 byte-for-byte 相同；feature flag 僅在 `startRecordingFlow()` 單點判斷。cancelRecording hotkey 亦正確呼叫 `audio.detachStreamingAccumulator()` + `streamingCoordinator?.cancelSession()`。
- **AudioBufferAccumulator thread safety**：lock/unlock 模式正確；callback 在 lock 釋放後呼叫，無死鎖風險；文件明確警告不可重入。
- **CPU monitor 計算**：`host_cpu_load_info_data_t` 含 4×UInt32 欄位，`MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size` = 4，與 `HOST_CPU_LOAD_INFO_COUNT` 宏等價，正確。
- **Focus guard timeout**：10s 後呼叫 `cancelSession()`，cancel 路徑正確清除 accumulator（`accumulator = nil`）。timeout Task 在 `isFocusPaused` 為 false 時 early-return，不誤殺已恢復的 session。
- **Discovery badge**：`V1UsageCounter.shouldShowDiscoveryBadge` 三重 guard（count、dismissed、streamingEnabled）正確；`SettingsView` 在 toggle 變 true 時立即 dismiss，`@AppStorage` 自動持久化。
- **停止流程中 fullWavURL 時序**：`audio.stopRecording()` 先於 `streamingCoordinator.updateFullWavURL()` → `endSession()`，URL 在 `runFullPass()` 前已確定，無 race。
- **AppState.streaming 未在 AppCoordinator state machine 使用**：streaming 錄音期間 coordinator state 為 `.recording`，`.stopRecording` hotkey guard (`state == .recording`) 正確攔截。AppState.streaming 僅供 pill 顯示。
- **in-flight chunk transcription 在 endSession 後丟棄**：endSession 轉 `.finalizing`，`handleChunkTranscription` 的 `guard case .streaming` 攔截，不污染 streamingChunks。
- **測試品質**：31 tests 覆蓋所有核心路徑；mocks 正確隔離 AX/clipboard side effects；temp WAV helper 可重用。`CPULoadMonitorTests` 用 threshold 邊界值測試，簡潔可靠。

---

## 已知缺口（非本次阻擋）

- AX replace spike #4（`V3AXSelectReplaceTests`）仍為手動測試。QA/UT 需在 5 target apps 驗證。P1-2 修正後此項優先級下降。
- `waitForStreamingDone` polling（P2-2）可延後至 Phase 2。
- `AppState.streaming` 未實際賦值給 `AppCoordinator.state`——pill 從 `streamingCoordinator.sessionState` 取 chunkCount 而非從 AppState.streaming——略顯冗餘。可在 Phase 2 清理。

---

**out:** CHG:3。P0-1 修完後重新 review 快速確認即可，P1/P2 可同批提交。
