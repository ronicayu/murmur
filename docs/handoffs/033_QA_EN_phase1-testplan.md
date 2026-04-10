---
id: 033
from: QA
to: EN
status: RDY
topic: phase1-testplan
date: 2026-04-10
---

# Handoff: Phase 1 Test Plan — QA → EN

## 摘要

Phase 1 Audio Transcription之完整測試計劃已完成，寫於：

```
docs/test-plans/phase1-audio-transcription.md
```

**總測試數：60（自動化55，Manual 5）**

---

## 各類別摘要

| 類別 | 數量 | 文件（建議位置） |
|------|------|----------------|
| Unit Tests — Swift | 18 (UT-001–024) | `MurmurTests/TranscriptionServiceTests.swift` 等 |
| Integration Tests — Swift | 12 (IT-001–012) | `MurmurTests/IntegrationTests/` |
| UI Tests — XCUITest | 16 (UI-001–019) | `MurmurUITests/AudioTranscriptionUITests.swift` |
| Edge Case Tests | 14 (EC-001–014) | 混合XCTest / XCUITest |
| Manual | 5 (MT-001–005) | 人工執行，見test plan § 5 |

---

## EN需實現之測試基礎設施

以下mock/fixture類在test plan中被引用，需EN實作（或由QA補充PR）：

| 類別 | 用途 |
|------|------|
| `MockPythonProcess` | stub transcribe.py輸出；支持`.stubbedLines`、`.blockAfterFirstLine`、`.crashingProcess()`、`.slowSuccess()` |
| `MockVoiceInputController` | stub voice input state machine；提供`.state`屬性 |
| `MockAudioRecorderService` | stub AVAudioRecorder行為；支持`.state: .recording/.stopped` |
| `TestAudioFixture` | 靜態helper：創建silent m4a、dummy URL with duration、mp3/wav URLs |
| `TranscriptionHistoryStore(suiteName:)` | 測試用UserDefaults suite隔離；`.nukeForTesting()` |
| `DiskSpaceChecker(availableBytes:currentM4aUsageBytes:)` | 注入式磁盤空間查詢，避免依賴真實磁盤 |
| `ChunkBoundaryCalculator` | 純函數，建議無側效應——便於直接單元測試 |
| `OrphanM4ACleaner(history:directory:)` | 孤兒m4a掃描邏輯注入測試目錄 |

---

## 與030 handoff之關係

EN之030 handoff請QA確認4項：

| EN請求 | 本計劃對應 |
|--------|-----------|
| CI unit+integration全通過 | Python tests已有（Layer 1+2）；Swift mirror見UT-007–011 |
| 真實長音頻 --system test | 標記為System test，需真實模型；見測試計劃§6缺口 |
| model-not-loaded error JSON | IT-002覆蓋 |
| edge cases補充 | EC補充：EC-003(零長度)、EC-004(損壞m4a)、UT-010(chunk<overlap) |

---

## 關鍵約束提醒（測試設計依據）

以下spec約束在測試中均有對應case，EN實現時請確認：

1. **磁盤：** < 1GB拒絕錄音（EC-005）；m4a 80% cap警告（EC-006）；100% cap拒絕（UT-024）
2. **格式：** .wav拒絕（IT-006, EC-007, UI-009）；.mp3/.m4a/.caf/.ogg通過
3. **時長：** > 2hr拒絕（IT-007, EC-008）；= 2hr通過（EC-009邊界值）
4. **History：** 50筆上限，第51筆淘汰最舊（UT-013）；跨session persist（IT-010–012）
5. **並發：** 轉寫中拒絕第二個（EC-012, EC-013）
6. **Cancel：** partial result不寫history（EC-003）；m4a刪除（EC-004）；voice input恢復（UT-004）
7. **失敗：** m4a保留供retry（EC-014）；history狀態.failed

---

## Manual Tests需協調

MT-001至MT-005建議EN實現後由@UT執行。QA可提供測試步驟說明。
特別是MT-003（App Nap/鎖屏）需要真實Mac環境，CI無法涵蓋。

---

## Python測試對齊

`Murmur/Scripts/test_chunked_transcribe.py` Layer 1之chunk boundary數值須與
Swift `ChunkBoundaryTests`（UT-007–011）一致。若EN修改chunk計算邏輯，兩端須同步更新。

---

out: `docs/test-plans/phase1-audio-transcription.md`

---

*@QA — 2026-04-10*
