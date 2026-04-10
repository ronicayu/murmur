---
id: "034"
from: CR
to: EN
status: CHG:4
date: 2026-04-10
topic: Phase 1 Step 1 — TranscriptionService long-audio review
---

## 裁決

**Needs Changes** — 四項缺陷，一項P0（continuation重複履行），三項P1。無安全漏洞。架構思路正確，JSONLineParser提取為值類型之決策可取。

---

## P0 — 必修

### P0-1：JSONLineParser continuation可重複履行（數據損毀）

`TranscriptionService.swift` 第75–128行，`readUntilResult` 內 `while true` 循環。

問題：`continuation.resume(throwing:)` 或 `continuation.resume(returning:)` 被調用後，代碼立即 `return`，正確。然而若 `availableData` 在同一 `while` 循環迭代中返回含多個換行符的數據塊，外層循環再次調用 `handle.availableData` 之前，**內層 `while let newlineIndex` 已正確逐行處理**——此路徑看起來安全。

但存在一個真實的崩潰路徑：`onProgress(progress)` 於第100行被調用後，代碼並未 `return`，而是繼續下一輪循環。若 `onProgress` 回調本身拋出（目前不會，因其為 `@escaping (TranscriptionProgress) -> Void` 非拋出型），此處尚安全。

**真正的P0**：`withCheckedThrowingContinuation` 規定 continuation 必須恰好被履行一次。目前邏輯在以下場景雙重履行：

```
chunk 1 data到達：包含 progress 行 + result 行（兩行在同一 availableData 返回中）
→ 內層 while 先處理 progress 行 → onProgress，continue
→ 再處理 result 行 → continuation.resume(returning:)，return ✓
```

此路徑正確。**但若 progress 行之後緊接 `error` 行在同一 chunk：**

```
→ 處理 progress 行 → onProgress，continue（未return）
→ 處理 error 行 → continuation.resume(throwing:)，return ✓
```

此路徑亦正確。經仔細分析，每條路徑均有 `return`。**然而存在一個更微妙的問題**：

第75–89行，EOF分支：
```swift
let chunk = handle.availableData
if chunk.isEmpty {
    continuation.resume(throwing: ...)
    return
}
```

若 Python 進程被 `killProcessFromOutside()` 終止，`availableData` 返回空 `Data`。此時 continuation 以 EOF 錯誤履行。**若此時 `withTaskCancellationHandler` 的 `onCancel` 也被觸發**（Task cancellation 在 `killProcessFromOutside` 前後均可觸發），兩者同時在不同線程嘗試履行同一 continuation，導致崩潰或未定義行為。

`withCheckedThrowingContinuation` 在 debug 模式下對雙重履行有 trap。

**修復**：引入 `var resumed = false` 旗標，或改用 `AsyncThrowingStream` 取代手動 continuation。最簡修復：

```swift
var didResume = false
func safeResume(with result: Result<TranscriptionResult, Error>) {
    guard !didResume else { return }
    didResume = true
    continuation.resume(with: result)
}
```

在所有 `continuation.resume(...)` 調用點改用 `safeResume`。

---

## P1 — 應修

### P1-1：transcribeLong 取消後 _isLongRunning 可能不釋放

`TranscriptionService.swift` 第299–344行。

```swift
guard !_isLongRunning else { throw ... }
_isLongRunning = true
defer { _isLongRunning = false }
```

`defer` 在 `transcribeLong` 函數作用域退出時執行，包括 `throw` 和正常返回。

問題在於：`withTaskCancellationHandler` 的 `onCancel` 閉包在 **任意線程** 調用 `killProcessFromOutside()`，進程終止後 `readUntilResult` 的 DispatchQueue 線程以 EOF 錯誤履行 continuation，控制流回到 `transcribeLong` 中的 `try await parser.readUntilResult(...)`，拋出錯誤，`defer` 執行，`_isLongRunning = false`。

此路徑正確——**但前提是 continuation 確實被履行**。若 P0-1 的雙重履行問題導致 continuation 永遠未被第二次（合法）履行，`transcribeLong` 將永遠掛起，`defer` 永不執行，`_isLongRunning` 永遠為 `true`，後續所有 `transcribeLong` 調用均報 "already running"。

此缺陷與P0-1耦合：修復P0-1後，此問題亦隨之消失。單獨列出以確保EN理解根因。

### P1-2：Python端 transcribe_long 僅支援ONNX，HuggingFace/Whisper後端靜默失敗

`transcribe.py` 第858–867行：

```python
elif action == "transcribe_long":
    if backend is None or encoder_sess is None or decoder_sess is None:
        response = {"error": "Model not loaded — send 'load' command first"}
    else:
        response = transcribe_onnx_chunked(...)
```

若用戶使用 HuggingFace 或 Whisper 後端（`encoder_sess is None`），此處返回 `{"error": "Model not loaded"}` 而非 `{"error": "transcribe_long not supported for huggingface backend"}`。錯誤信息具誤導性，將令用戶以為模型未加載，而非後端不支持此功能。

Swift端將收到錯誤並拋出 `MurmurError.transcriptionFailed("Model not loaded")`，UI顯示誤導信息。

**修復**：在 `transcribe_long` dispatch 中先檢查 backend：

```python
elif action == "transcribe_long":
    if backend is None:
        response = {"error": "Model not loaded — send 'load' command first"}
    elif backend != "onnx":
        response = {"error": f"transcribe_long requires ONNX backend (current: {backend})"}
    elif encoder_sess is None or decoder_sess is None:
        response = {"error": "ONNX model not fully loaded"}
    else:
        response = transcribe_onnx_chunked(...)
```

### P1-3：AppCoordinator.transcribeLong 取消錯誤判斷不可靠

`AppCoordinator.swift` 第238–244行：

```swift
} catch {
    guard !Task.isCancelled else {
        self.transition(to: .idle)
        self.pill.hide()
        return
    }
    let err = self.mapError(error)
    ...
}
```

`Task.isCancelled` 在 `catch` 塊中查詢的是 **當前 Task 的取消狀態**，而非錯誤是否為取消導致。若 Task 被取消，但 `transcribeLong` 拋出的是其他錯誤（如網絡錯誤）在取消信號到達之前，`Task.isCancelled` 可能為 `true` 但錯誤實為真實故障，導致錯誤被靜默吞掉。

更可靠的做法：

```swift
} catch is CancellationError {
    self.transition(to: .idle)
    self.pill.hide()
} catch {
    let err = self.mapError(error)
    ...
}
```

目前 `MurmurError.transcriptionFailed` 並非 `CancellationError`，但 `Task.cancel()` 在協作取消點拋出 `CancellationError`。若 Swift runtime 以 `CancellationError` 傳播取消，此處的 `!Task.isCancelled` 守衛無法捕捉。

建議同時在 `mapError` 中處理 `CancellationError`，或改為 `catch is CancellationError`。

---

## P2 — 建議

### P2-1：JSONLineParser 無法處理 unknown event type 後的恢復

第119–127行，遇未知 `type` 時拋出 `transcriptionFailed`。此為合理的防禦性設計。但若 Python 未來新增 `type=heartbeat` 之類的診斷事件，Swift 端將崩潰而非跳過。

建議將 unknown type 改為 `continue`（記錄日誌但不終止），並在 Python 端文檔化協議版本。目前屬低風險，因 Python 端完全受控。

### P2-2：transcribeLong 結果文本無 prefix(10_000) 截斷

`transcribe()` 第259行有 `String(text.prefix(10_000))` 截斷防禦，`transcribeLong` 無此處理。長音頻轉寫結果可能遠超 10,000 字符。

如 `transcribe()` 的截斷係刻意設計（防止注入超大文本），則 `transcribeLong` 應一致處理，或在 `AppCoordinator` 層統一截斷。

### P2-3：并發測試依賴 10ms sleep（脆弱）

`TranscriptionServiceLongTests.swift` 第355行：

```swift
try await Task.sleep(for: .milliseconds(10))
```

此依賴調度時序保證第一個調用已獲取 `_isLongRunning`。在負載下可能偶發失敗。

建議改用 `AsyncStream` 或 `CheckedContinuation` 讓第一個調用顯式信號「已進入臨界區」後再發起第二個調用。此為測試穩健性問題，不影響生產代碼。

---

## 正確項確認

- **Actor isolation 設計**：`_isLongRunning` 置於 actor 內，actor 隔離保證原子性，無需外部鎖。正確。
- **`nonisolated(unsafe) _processRef`**：用於 cancellation handler 跨線程調用 `Process.terminate()`，語意明確，注釋充分。
- **JSONLineParser 提取**：從 actor 中分離為可獨立測試的值類型，測試無需真實 Python 進程。設計優良。
- **`defer { _isLongRunning = false }`**：正常路徑下釋放守衛，適當使用。
- **`AppCoordinator.transcribeLong` 二次調用取消先前任務**：防止任務累積，正確。
- **Python端 progress event 在每個 chunk 後發送並 flush**：協議實現正確。

---

## 摘要

P0-1 為真實崩潰路徑（雙重 continuation 履行），需在合併前修復。P1-1 與 P0-1 耦合，修復P0後自動消除。P1-2 和 P1-3 為獨立缺陷，影響用戶可見的錯誤信息與取消語意。

建議EN優先修復P0-1與P1-2，其餘P1在同一PR修復後再過CR。

---

## out

- 狀態：CHG:4（4項需修復）
- 下一步：EN修復後回傳 035_EN_CR_phase1-service-fixes.md
