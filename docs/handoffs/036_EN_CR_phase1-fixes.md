---
id: "036"
from: EN
to: CR
status: RDY
date: 2026-04-10
topic: Phase 1 Step 1 — TranscriptionService CR fixes (P0 + P1x3 + P2x3)
---

## 摘要

修復034號CR裁決所列全部7項缺陷。全套90測試通過，零退化。

---

## 修復清單

### P0-1 — continuation雙重resume（已修）

**文件**：`Murmur/Services/TranscriptionService.swift`

引入`UnfairLock`包裝`os_unfair_lock`，在`readUntilResult`內以`didResume: Bool`守衛所有
`continuation.resume`調用點。具體做法：

```swift
let resumeLock = UnfairLock()
var didResume = false

func safeResume(with result: Result<TranscriptionResult, Error>) {
    resumeLock.withLock {
        guard !didResume else { return }
        didResume = true
        continuation.resume(with: result)
    }
}
```

全部6處原`continuation.resume(…)`改為`safeResume(with:)`。

Task cancellation handler（`killProcessFromOutside()`）與DispatchQueue EOF路徑並發觸發時，
第二次resume被`resumeLock`攔截，不再崩潰。

---

### P1-1 — `_isLongRunning`永久鎖死（已消除）

P0-1修復後，continuation必然被履行一次，`readUntilResult`必然返回或拋出，控制流回到
`transcribeLong`，`defer { _isLongRunning = false }`必然執行。此問題隨P0-1消除，無獨立改動。

---

### P1-2 — Python `transcribe_long`非ONNX backend錯誤信息（已修）

**文件**：`Murmur/Resources/transcribe.py`

在`elif action == "transcribe_long"`分支中，先檢查`backend is None`，
再檢查`backend != "onnx"`，最後才檢查`encoder_sess/decoder_sess`：

```python
if backend is None:
    response = {"error": "Model not loaded — send 'load' command first"}
elif backend != "onnx":
    response = {"error": f"transcribe_long requires ONNX backend (current: {backend})"}
elif encoder_sess is None or decoder_sess is None:
    response = {"error": "ONNX model not fully loaded — send 'load' command first"}
else:
    response = transcribe_onnx_chunked(...)
```

HuggingFace/Whisper用戶現收到明確的「requires ONNX backend」錯誤，不再被誤導為「Model not loaded」。

---

### P1-3 — AppCoordinator取消錯誤判斷（已修）

**文件**：`Murmur/AppCoordinator.swift`

`transcribeLong`的catch塊由：

```swift
} catch {
    guard !Task.isCancelled else { ... }
    ...
}
```

改為：

```swift
} catch is CancellationError {
    self.transition(to: .idle)
    self.pill.hide()
} catch {
    let err = self.mapError(error)
    ...
}
```

`catch is CancellationError`直接匹配Swift runtime傳播的`CancellationError`，
不依賴`Task.isCancelled`在catch塊中的不確定狀態。

---

### P2-1 — Unknown event type應continue（已修）

**文件**：`Murmur/Services/TranscriptionService.swift`

`readUntilResult`中`else`分支（未知type）由`continuation.resume(throwing:) + return`
改為`os_log(.info, …)`後繼續內層while循環，保持前向相容性。

---

### P2-2 — `transcribeLong`結果截斷（已修）

**文件**：`Murmur/Services/TranscriptionService.swift`

`transcribeLong`返回前加`String(result.text.prefix(10_000))`，
與`transcribe()`第259行行為一致。

---

### P2-3 — 並發測試sleep改expectation（已修）

**文件**：`Murmur/Tests/TranscriptionServiceLongTests.swift`

新增`FakeLongTranscriptionGateSignaling` actor，以`CheckedContinuation<Void, Never>`
實作「已進入臨界區」信號。測試調用`await fakeLong.waitUntilInside()`代替
`try await Task.sleep(for: .milliseconds(10))`，消除時序脆弱性。

原`FakeLongTranscriptionGate`保留供`test_transcribeLong_gateReleasedAfterCompletion`使用。

---

## 測試結果

```
Executed 90 tests, with 0 failures (0 unexpected)
```

所有既有測試通過，無退化。

---

## 修改文件彙整

| 文件 | 改動 |
|------|------|
| `Murmur/Services/TranscriptionService.swift` | P0-1 `UnfairLock` + `safeResume`；P2-1 unknown type continue；P2-2 prefix(10_000) |
| `Murmur/AppCoordinator.swift` | P1-3 `catch is CancellationError` |
| `Murmur/Resources/transcribe.py` | P1-2 ONNX backend判斷 |
| `Murmur/Tests/TranscriptionServiceLongTests.swift` | P2-3 `FakeLongTranscriptionGateSignaling` |

---

## CR審閱要點

1. `UnfairLock`在closure中捕獲`didResume`——lock scope是否足夠窄？
2. `safeResume`在`withCheckedThrowingContinuation`的DispatchQueue閉包內聲明為局部函數，
   是否有意外捕獲？
3. `FakeLongTranscriptionGateSignaling.waitUntilInside()`若在first call進入前被調用，
   continuation會被保存；若在first call進入後被調用，`hasSignalled == true`直接返回。
   此競態是否覆蓋完整？

---

## out

- 狀態：RDY
- 下一步：CR複審後若LGTM，可合併；若仍有CHG，回傳EN
