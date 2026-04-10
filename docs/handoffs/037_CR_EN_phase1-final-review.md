---
id: "037"
from: CR
to: EN
status: LGTM
date: 2026-04-10
topic: Phase 1 final review — service layer + UI layer + P0/P1/P2 fixes
---

## 裁決

**LGTM with nits.** 無P0。一項P1（catch塊誤用`Task.isCancelled`），三項nit。可合併。

---

## P0 驗證

### P0-1 — 雙重resume

`UnfairLock` + `didResume` 守衛正確。所有六處`continuation.resume`已改為`safeResume(with:)`。lock scope窄（僅guard + set flag + resume），閉包無意外捕獲。

`withTaskCancellationHandler`之`onCancel`呼叫`killProcessFromOutside()`；DispatchQueue路徑呼叫`safeResume`；兩路均受鎖保護。竟態覆蓋完整。

---

## P1

### P1（新發現）— `TranscriptionWindowModel.beginTranscription` catch塊

**文件**：`Murmur/Views/TranscriptionWindowModel.swift:238`

```swift
} catch {
    guard !Task.isCancelled else { return }
    ...
}
```

`Task.isCancelled` 在`catch`塊中查詢的是**當前task**的取消狀態，而非拋出錯誤的類型。若`CancellationError`在`catch`前抵達，`Task.isCancelled`可能為`false`，導致`failed`狀態誤報至history。

`AppCoordinator.transcribeLong`已在P1-3修正為`catch is CancellationError`，此處未跟進。

**修法**：

```swift
} catch is CancellationError {
    // 取消：靜默清理，不標記failed
    if let id = self.activeEntryID {
        try? historyService.delete(id: id)
        activeEntryID = nil
    }
    windowState = .idle
} catch {
    Self.log.error("Transcription failed: \(error)")
    if let id = self.activeEntryID {
        try? historyService.updateStatus(id: id, status: .failed)
        activeEntryID = nil
    }
    windowState = .idle
}
```

---

## 架構

**清晰。**`TranscriptionService`（actor）→ `AppCoordinator`（@MainActor）→ `TranscriptionWindowModel`（@MainActor ViewModel）→ SwiftUI Views 分層明確，無越層呼叫。`JSONLineParser` 提取為值類型可獨立測試，設計正確。

---

## Concurrency / Thread Safety

`UnfairLock` 用法正確，`@unchecked Sendable` 標注恰當（class持鎖，無unsafe存取）。

`FakeLongTranscriptionGateSignaling.waitUntilInside()`之競態分析：
- `waitUntilInside()`在信號前調用 → continuation被保存，`transcribeLong`進入後resume。
- `waitUntilInside()`在信號後調用 → `hasSignalled == true`，直接返回。

兩路均正確，無懸掛continuation風險。

`nonisolated(unsafe) _processRef`：用於cancellation handler跨actor取用，`Process.terminate()`本身是thread-safe，用法正確。

---

## 記憶體

`TranscriptionWindowController` 以`NotificationCenter.addObserver(self:…)`持有強引用self，但`deinit`僅移除`globalHotkeyMonitor`，未移除Notification observer。在app lifecycle中`TranscriptionWindowController`存活至app終止，故實際無洩漏；若未來改為可提前釋放須補`removeObserver`。

`LongRecordingService.maxDurationTask`用`[weak self]`，正確防止循環引用。

`RecordingView`的`Timer.publish(...).autoconnect()`在view消失時由SwiftUI自動取消，無洩漏。

---

## macOS API

`activationPolicy`切換：`openOrFocus()`切`.regular`，`windowWillClose`切回`.accessory`。符合Phase 0 spike結論。

`win.isReleasedWhenClosed = false`正確（NSHostingView window必須）。

`NSEvent.addGlobalMonitorForEvents`需Accessibility permission。此為已有行為（V1 undo monitor同樣做法），不新增風險。

---

## V1 兼容性

`MenuBarView`僅新增`openTranscriptionButton`及`onOpenTranscription`回調，未改動既有狀態機路徑。`AppCoordinator.transcribeLong`進入`.transcribing`態，`handleHotkeyEvent`中既有`state == .transcribing → pendingRecording = true`邏輯自然抑制新錄音。V1 popover voice input不受影響。

---

## Nits

**Nit-1** — `TranscriptionWindowView.groupedHistory` 過去一週分組鍵為weekday名稱（字串），排序為字母序（Mon < Thu < Tue），非時間序。建議改以date值排序：

```swift
// 替換
.sorted()
// 改為
.sorted { lhs, rhs in
    // 以bucket中第一筆entry.date排序（降序）
    let lhsDate = buckets[lhs]?.first?.date ?? .distantPast
    let rhsDate = buckets[rhs]?.first?.date ?? .distantPast
    return lhsDate > rhsDate
}
```

**Nit-2** — `transcribe_onnx_chunked`（Python）：每個chunk完成後均emit progress event，包括`chunk_text == ""`的靜音chunk；此時`partial_text`與上一次相同。Swift UI側ProgressView不jitter（進度百分比仍遞增），但多餘callback輕微浪費。可在靜音chunk跳過`sys.stdout.write`。

**Nit-3** — `validateAndConfirmUpload`中直接`SystemDiskSpaceChecker()`實例化，繞過DI。磁盤check在此為輔助判斷（LongRecordingService.startRecording會再check一次），影響輕微，但與其他DI模式不一致。可改傳入`diskChecker`或直接複用`recordingService`中的checker。

---

## 測試

22個新增測試覆蓋充分。`PipeSimulator`方案避免真實subprocess，正確。`FakeLongTranscriptionGateSignaling` P2-3修正消除sleep脆弱性，值得肯定。

---

## out

- 狀態：LGTM（P1修完後可合併，nit可選）
- 下一步：EN修復`TranscriptionWindowModel` catch塊後合併；或接受nit作next PR
