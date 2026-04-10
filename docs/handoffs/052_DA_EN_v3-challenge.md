# Handoff 052 — DA → EN: V3 Phase 1 Challenge

**From:** DA
**To:** EN
**Status:** RDY
**Date:** 2026-04-10
**Re:** V3 Streaming Voice Input — Phase 1 implementation challenge

---

## 總論

168 tests pass。State machine結構清晰。Feature flag隔離V1無誤。然有六處根本缺陷，其中二者為P0，不解決則Phase 1不可ship。

---

## 挑戰一：replaceRange在真實app中不可靠 【P0】

**問題：**

`TextInjectionService.attemptAXReplaceRange()` 透過 `kAXSelectedTextRangeAttribute` set + `kAXSelectedTextAttribute` set 執行替換。此路徑在真實app中有以下已知行為：

- **Electron apps（VS Code、Obsidian）：** `kAXSelectedTextRangeAttribute` set 通常返回 `.success`，但實際並未移動游標。後續 `kAXSelectedTextAttribute` set 替換空選取或錯誤位置。靜默失敗。
- **Terminal / 某些web textarea：** AX整個不支援，返回 `AXError.apiDisabled` 或 `.attributeUnsupported`。現有code會fallback到 clipboard paste——但此時已有streaming text在游標位置，paste會**疊加**而非替換，造成重複輸出。
- **Character offset vs. byte offset：** `CFRange.location` 在含multi-byte Unicode（中文、emoji）的文字中，不同app對「character」定義不一。VSCode以UTF-16 code unit計，AppKit以NSString character計，兩者可能不同。offset錯位 → 替換錯誤位置。

**規格未解決：** spec rev 4第4項「AX replace TBD」、conditional deferral維持，但Phase 1已實作並啟用此路徑，並無 ≥3/5 app驗證結果。Phase 0 spike #4標記「未測」。

**要求EN回答：**

1. Phase 0 spike #4（AX replace + 5個app）**何時執行？結果為何？**
2. 若 <3/5 可行，是否已有機制在runtime停用 `replaceRange`，降級為append-only？現行code無此判斷。
3. Clipboard fallback疊加問題確認：`replaceRange` 失敗後 fallback 呼叫 `inject(text:)`，此時游標在streaming text末尾，paste會再加一份full-pass text。是否有測試覆蓋此edge case？

---

## 挑戰二：InjectedRangeTracker假設游標只由我們移動 【P0】

**問題：**

`InjectedRangeTracker` 以 `startOffset + totalLength` 重建 AX range。此假設：**streaming期間游標未被外力移動**。

真實情況：

- 用戶說話時可能同時按方向鍵、Home、End、Backspace修正前文。
- appendText 透過 clipboard paste (Cmd+V) 執行——paste後游標在注入文字末尾，但若用戶mid-session移動游標，下一chunk的append位置即已錯位。
- 更嚴重：full-pass的 `replaceRange(start: tracker.startOffset, length: tracker.totalLength, ...)` 此時指向錯誤range，替換將覆蓋**用戶手動鍵入之內容**。

Spec constraint §4：「不可覆蓋用戶既有內容或中間編輯」。現行實作**無法偵測用戶mid-session游標移動**，直接違反此約束。

FocusGuard僅偵測app-level focus（`NSWorkspace.didActivateApplicationNotification`），**不偵測同一app內的游標移動**。

**要求EN回答：**

1. 用戶mid-session按方向鍵後，下一個chunk的appendText注入位置是否正確？有無測試？
2. full-pass replaceRange在游標已移動情況下，是否有保護機制？
3. Spec §5第三條「若用戶於streaming文字中間編輯→放棄替換」——現行code如何偵測此情況？答案似乎是：完全沒有。

---

## 挑戰三：Focus guard 10s timeout對「查資料再回來」場景過短 【P1】

**問題：**

`focusAbandonSeconds = 10.0`。用戶口述技術文件時，常需切到browser查一個詞再切回繼續說。10秒對此場景過短。

更嚴重的是timeout實作方式：

```swift
Task { @MainActor [weak self] in
    try? await Task.sleep(for: .seconds(Self.focusAbandonSeconds))
    guard self.isFocusPaused, case .streaming = self.sessionState else { return }
    self.cancelSession()
}
```

此Task在 `focusLeft` 時建立，在 `focusReturned` 時**不取消**。若用戶在9.9s返回（`isFocusPaused` 置為false），此Task仍會在0.1s後執行。此時 `isFocusPaused == false`，guard通過，**但 `sessionState` 仍為 `.streaming`，session被錯誤取消**。

競態條件（race condition）：`focusReturned` 設 `isFocusPaused = false`，但Task的guard check在下一個await點才執行，兩者順序在高負載下不確定。

**要求EN回答：**

1. 為何不持有Task handle並在 `focusReturned` 時cancel？
2. 10s hardcode依據為何？有無辦法讓用戶可調（Settings）？

---

## 挑戰四：全文full-pass與streaming並行的磁碟I/O 【P1】

**問題：**

Streaming期間：
- AVAudioEngine持續寫全文WAV到磁碟（供full-pass用）
- 每個chunk另寫一個temp WAV（`murmur_chunk_UUID.wav`）供chunk transcription用
- Transcription ONNX同時讀chunk WAV

三個I/O流同時打開。M1 8GB SSD write bandwidth有限，加上ONNX CPU推理，**Phase 0 CPU測試為28% avg，但未量測I/O wait**。

Temp chunk WAV的清理：`processChunkBuffer` 呼叫 `writeBufferToTempWAV` 後，chunk WAV在transcription task完成後**沒有刪除**（`try? FileManager.default.removeItem(at: chunkURL)` 僅在 `self` 為nil時執行）。30s錄音 = 10個chunk = 10個temp WAV殘留。

**要求EN回答：**

1. Chunk WAV是否在transcription完成後刪除？若否，30s session後有多少磁碟垃圾？
2. 是否有量測streaming session期間的磁碟I/O？Phase 0未見此數據。

---

## 挑戰五：Full-pass等待時間——30s錄音等30s 【P1】

**問題：**

Full-pass RTF在Phase 0測為~0.6x（3s chunk需1.93s推理），全文30s音頻需~18s推理。

`waitForStreamingDone()` hard timeout為30s。用戶鬆開hotkey後，app在 `.transcribing` 狀態最多等待30s，期間：
- Pill顯示「Transcribing...」
- 用戶無法發起新錄音（state != .idle）
- 若full-pass超時（30s），coordinator被cancelSession，**streaming版本保留但無任何通知**

spec §5：「替換window：full-pass完成後500ms內執行。逾時則放棄。」——但此500ms window與30s等待無關，`replaceWindowSeconds = 0.5` 僅用於replace操作本身，不限制full-pass等待時間。用戶實際等待由full-pass推理時長決定（可達30s），非0.5s。

**要求EN回答：**

1. 30s錄音的full-pass用戶需等多久？Phase 0有無量測？
2. 若full-pass需18s，用戶體驗為何？是否有進度指示？
3. `waitForStreamingDone` timeout後用戶是否知道替換沒發生？

---

## 挑戰六：Test覆蓋率——Mock vs真實pipeline 【P2】

**問題：**

168 tests中，V3相關tests（V3Phase1Tests.swift）使用 `MockTranscriptionService` 和 `MockTextInjectionService`。Mock的行為與真實實作差異：

1. `MockTranscriptionService.transcribe()` 同步返回stubbed result，無I/O、無延遲。真實TranscriptionService透過Python子進程通訊，有latency、有timeout、有crash風險。**無任何test驗證streaming coordinator在transcription timeout或subprocess crash時的行為。**

2. `MockTextInjectionService.appendText()` 直接記錄字串，無clipboard操作、無CGEvent。真實路徑中，clipboard restore有1500ms sleep（`injectViaClipboard`），streaming期間每個chunk等待1.5s意味著3s chunk window內只能執行一次注入。多chunk backlog時有何行為？未測。

3. `test_cpuMonitor_stop_preventsSubsequentCallbacks` 以 `threshold: 0.0` 觸發，但此test非確定性——`callbackCount` 在stop前可為0或1，test僅檢查stop後不再增加，未驗證callback確實曾觸發。

4. 整個streaming → chunk → transcription → inject → rangeTracker → full-pass → replaceRange pipeline **無端到端integration test**。每個環節獨立unit測試，但pipeline組合行為（如chunk5轉寫回來時session已進入finalizing，inject被guard丟棄）未測。

**要求EN回答：**

1. 是否有計劃加入integration test？至少應測：正常2-chunk session、focus loss + resume、CPU fallback。
2. Clipboard 1500ms sleep與3s chunk window的交互是否已評估？

---

## 摘要評分

| # | 挑戰 | 級 | 狀態 |
|---|------|----|------|
| 1 | replaceRange真實app可行性——spike #4未測、fallback疊加bug | P0 | BLK：Phase 1不可ship直至spike #4完成或替換降級 |
| 2 | InjectedRangeTracker游標假設——違反spec constraint §4 | P0 | BLK：需偵測mid-session游標移動或放棄替換 |
| 3 | Focus guard 10s + race condition | P1 | CHG：需取消Task handle；timeout值需議 |
| 4 | Chunk WAV未清理 + I/O未量測 | P1 | CHG：加刪除邏輯；補I/O benchmark |
| 5 | Full-pass等待體驗（最長30s）+ 逾時無通知 | P1 | CHG：需進度指示或上限降低 |
| 6 | Mock覆蓋率不足——無pipeline integration test | P2 | CHG：補integration test |

**結論：** P0項目二者均為架構缺陷，非edge case。挑戰一（replaceRange）直接繼承自Phase 0未完成之spike #4；挑戰二（游標假設）為新發現。建議EN解決P0後方可進入QA/UT。

---

## in

- 讀 `Murmur/Services/StreamingTranscriptionCoordinator.swift`
- 讀 `Murmur/Services/AudioBufferAccumulator.swift`
- 讀 `Murmur/AppCoordinator.swift`
- 讀 `Murmur/Services/TextInjectionService.swift`
- 讀 `docs/specs/v3-streaming-voice-input.md` rev 4
- 讀 `Murmur/Tests/V3Phase1Tests.swift`

## out

`docs/handoffs/052_DA_EN_v3-challenge.md` — 六挑戰，二P0，四P1/P2。
