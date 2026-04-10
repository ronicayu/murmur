---
id: "038"
from: DA
to: EN
status: RDY
date: 2026-04-10
topic: Phase 1 mid-point challenge — 6項架構疑問
---

## 概覽

Phase 1核心實現已過CR（036）。90 tests pass。以下6項挑戰非吹毛求疵——每項皆有具體失效場景或用戶可感知缺陷。EN須逐項裁奪：接受現狀（附理由）、或制定補救方案。

---

## C1 — 單Python process瓶頸：問題比spec描述嚴重

**位置：** `TranscriptionService.swift`，`transcribeLong()`；`AppCoordinator.swift`，`stopAndTranscribe()`

**問題：**

spec Constraint #10：「transcription pauses voice input」。實現中，V1 voice input（`transcribe()`）與V2 long transcription（`transcribeLong()`）共享同一Python process及同一stdin/stdout pipe。

`transcribeLong`進行期間，`_isLongRunning = true`守衛阻止第二次`transcribeLong`，但`transcribe()`無此守衛——若用戶在long transcription期間觸發V1 hotkey，`transcribe()`會嘗試`send()`寫入同一pipe，與進行中的`transcribeLong`的DispatchQueue讀取線程產生協議層面的race condition。結果不是「pause」而是protocol corruption：stdin收到交錯命令、stdout讀取器讀到錯誤json行、Python process崩潰或返回garbage。

AppCoordinator雖在`state == .transcribing`時設`pendingRecording = true`（第273行），但：
1. 此guard只在hotkey handler中，不在`transcribeLong`的task context內
2. V2 `TranscriptionWindowModel.beginTranscription()`直接呼叫`coordinator.transcription.transcribeLong()`，繞過`AppCoordinator.transcribeLong()`的`self.transition(to: .transcribing)`

**失效場景：** 用戶在meeting transcription進行中說話→V1 hotkey觸發→process protocol corrupted→transcription完全失敗、歷史條目卡在inProgress。

**要求EN回答：**
- `transcribe()`是否需要`_isLongRunning`守衛？
- V2 TranscriptionWindowModel是否應通過AppCoordinator路由、或直接呼叫service？

---

## C2 — History JSON file：3項潛在問題

**位置：** `TranscriptionHistoryService.swift`

**問題2a — 50筆上限：**

spec第13條接受DA建議從20改為50。但50筆JSON with prettyPrinted，每筆含完整transcript text（最高10,000字）。worst case：50 × 10,000 chars ≈ 500KB UTF-8 → ~1MB prettyPrinted。每次寫入（add/delete/update）皆全量序列化寫盤。一次`updateStatus()`呼叫寫1MB是否可接受？特別是transcription完成後立刻呼叫`completeEntry()`——此時text最大。

**問題2b — 並發安全性：**

`@MainActor`確保Swift層序列化，但`persist()`最終呼叫`Data.write(to:options:.atomic)`。`.atomic`寫入用臨時文件+rename，對於crash recovery已足。但多個window（onboarding + transcription window同時開啟）皆持有同一`historyService`實例，兩者皆可觸發`add()`——此為同一actor，無問題。然而：app從外部被terminate（force quit）時，若正在`persist()`的write call中途，`.atomic`保障文件完整性，但in-memory `entries`已修改——重啟後load會得到舊狀態。這是可接受的trade-off還是需要WAL？

**問題2c — App crash時數據丟失窗口：**

`startRecording()`立即呼叫`historyService.add(entry)`（status: inProgress）。若app在錄音期間crash，`scanAndRecoverOrphans()`在下次啟動時會將其標記failed——此為已知機制，正確。但：`beginTranscription()`第205行的transcription task若在`completeEntry()`之前crash（transcription完成但寫盤前），history entry永遠是inProgress/failed，m4a也已被`transcribeLong()`在Python側處理完（但Swift側未刪）。用戶看到failed entry，實際上transcription已完成——無法重試（結果已丟失）。此為可接受的crash window還是需要checkpoint？

---

## C3 — activationPolicy切換：已知macOS問題

**位置：** `TranscriptionWindowController.swift`，`openOrFocus()`及`windowWillClose()`

**問題：**

Phase 0 spike test #8顯示「8/8 Swift tests pass」，但spike在controlled環境下執行。已知macOS regression（Sonoma 14.x+）：在以下情況`setActivationPolicy`有副作用：

1. **多Space環境：** `.accessory` → `.regular`切換後，若app在Space A執行，window在Space B開啟，`NSApp.activate(ignoringOtherApps: true)`可能將Space B強制前移至Space A。此為NSApplication已知behavior，非bug可修復，需UX層告知用戶。

2. **切換至`.accessory`的時機：** `windowWillClose`觸發時切回`.accessory`。但若onboarding window或settings window此時仍開啟，`.accessory`切換會導致Dock icon消失——用戶仍在與設定互動，但Dock icon不見。現況：`MurmurApp`有`settingsWindow`及`onboardingWindow`，`windowWillClose`無從知曉其他window狀態。

**要求EN回答：**
- `windowWillClose`是否應檢查其他window是否仍visible再決定是否切回`.accessory`？
- 多Space問題是否已在Phase 0 scenario測試中覆蓋，或僅單Space automated test？

---

## C4 — TranscriptionWindowModel職責膨脹

**位置：** `TranscriptionWindowModel.swift`（274行）

**現況職責清單：**
1. Window state machine（idle/recording/transcribing/result/…）
2. LongRecordingService lifecycle（start/stop/cancel）
3. File picker（`NSOpenPanel`）
4. File drop handling（format validation、disk space check）
5. History entry lifecycle（add/complete/delete/update）
6. TranscriptionService呼叫（via coordinator）
7. Audio duration extraction（`AVURLAsset`）
8. Transcription Task lifecycle（create/cancel/resume）

**問題：** File picker（NSOpenPanel）在ViewModel中執行blocking modal。`openFilePicker()`第129行：`panel.runModal()`——此為同步呼叫，在@MainActor上阻塞main thread直到用戶選擇。雖然AppKit允許此模式，但ViewModel直接操作NSOpenPanel違反SwiftUI-first的架構假設，且無法被測試（無法inject mock NSSavePanel）。

`validateAndConfirmUpload()`亦包含業務規則（format check、duration check、disk space check）——此邏輯應在何層？

**要求EN回答：** Phase 1範圍內是否已有拆分計畫，抑或此為刻意的「夠用就好」設計？若後者，Phase 2拆分的觸發條件是什麼？

---

## C5 — 測試覆蓋：mock密度問題

**位置：** `Tests/`目錄，共90 tests

**計數：**
- `AppCoordinatorTests.swift`：22個test，全部針對enum/struct行為（AppState equality、HotkeyEvent、MurmurError）。零個test觸碰AppCoordinator instance本身。
- `TranscriptionServiceLongTests.swift`：11個test，其中2個是Sendable/protocol shape test（編譯時驗證）；並發守衛test用`FakeLongTranscriptionGate`（parallel actor，非TranscriptionService本身）。
- `FakeTranscriptionService`、`FakeLongTranscriptionGate`、`FakeLongTranscriptionGateSignaling`：均為parallel actor，測試的是mock的行為，非production code路徑。
- `Phase0SpikeTests.swift`、`P0FixTests.swift`：多為property/struct test。

**核心問題：** `TranscriptionWindowModel`——系統最複雜的協調層——零個直接test。`AppCoordinator.handleHotkeyEvent()`、`stopAndTranscribe()`、`startRecordingFlow()`亦無test。

90個tests中，真正執行production code路徑（非mock）的有：
- `TranscriptionHistoryServiceTests`（16個）：真正讀寫disk，實為integration test
- `LongRecordingServiceTests`（9個）：inject mock diskChecker和recorderFactory，部分路徑覆蓋
- `JSONLineParser`相關（5個）：真正執行parser邏輯

估計：~30個tests有實質覆蓋，~60個tests驗證enum/struct/mock behavior。

**要求EN回答：** `TranscriptionWindowModel`無test是Phase 1已知缺口還是遺漏？QA testplan（033號）是否涵蓋此層？

---

## C6 — 中文overlap trimming：Phase 0已知問題未解

**位置：** `transcribe.py`，第736-742行

**問題：**

spec open question #5（Phase 1待辦）：「Word-count heuristic對無空格語言失效。Phase 1須實現character-based trimming。」

現況（第737行）：
```python
words = chunk_text.split()
if len(words) > words_to_trim:
    chunk_text = " ".join(words[words_to_trim:])
```

中文文本`split()`按空格切分。Cohere Transcribe輸出中文時，通常無詞間空格（例："今天天氣很好明天可能下雨"）。`split()`返回一個巨大token或極少token，`words_to_trim`（default=10）可能trim整個chunk（第741-742行：`chunk_text = ""`）或完全不trim。

**實際影響：** 中文長音頻每個chunk接縫處會出現重複句子（overlap未trim）或遺漏內容（整chunk被trim），且無warning。

**Phase 1 spec已明確要求解決此問題。現況是未解還是EN認為已sufficient？**

如未解，此為Phase 1 BLOCKER（spec open question #5為Phase 1強制項）。

---

## 要求EN行動

| 項目 | 嚴重度 | 要求 |
|------|--------|------|
| C1 — Python process共享 | HIGH | 確認V1/V2 pipe隔離機制或補守衛 |
| C2a — JSON寫盤大小 | LOW | 確認worst case可接受 |
| C2b — Atomic write trade-off | LOW | 確認此trade-off為已知且接受 |
| C2c — Crash window | LOW | 確認已知、無需checkpoint |
| C3 — activationPolicy多window | MED | 修`windowWillClose`加visibility check |
| C4 — ViewModel職責 | MED | 提供Phase 2拆分計畫 |
| C5 — 測試覆蓋 | MED | `TranscriptionWindowModel`測試補充計畫 |
| C6 — 中文overlap | HIGH (BLOCKER) | Phase 1必須修，或EN提出rebut |

EN回應寫至 `docs/handoffs/039_EN_DA_phase1-response.md`。

---

## in

DA讀：TranscriptionService、HistoryService、LongRecordingService、TranscriptionWindowView/Model/Controller、AppCoordinator、MurmurApp、spec、Tests目錄（全7文件）。

## out

6項挑戰，含代碼引用、行號、失效場景。最重要：C1（pipe protocol corruption）及C6（中文trimming BLOCKER）。
