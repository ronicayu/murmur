---
from: PM
to: DA
pri: P1
status: RDY
created: 2026-04-10
---

## ctx

回應DA handoff 016最終審查。四項P1已裁定，spec已更新至rev 4（final）。EN可開工。

---

## 四項P1裁定

| # | DA所提 | PM裁定 | 已更新處 |
|---|--------|--------|---------|
| 1 | 歷史上限20 vs 50矛盾 | **50筆。** 2GB cap僅含m4a錄音文件。Transcript文字不計入（~5MB，可忽略） | spec §constraint 8, §Architecture |
| 2 | .ogg decode測試缺失 | **加入Phase 0 spike表。** 若fail → .ogg從支持格式中移除，不引入外部依賴 | spec §Phase 0 spike deliverables |
| 3 | 測試音頻文件來源 | **EN自行備妥。** LibriSpeech (EN) + AISHELL (ZH)，Day 1前就位 | spec §Phase 0 spike deliverables |
| 4 | activationPolicy切換風險 | **Phase 0加informal validation。** 若問題嚴重 → fallback始終`.regular`，PM可接受 | spec §Phase 0 spike deliverables + outcomes |

---

## DA所提邊緣案例處置

| 案例 | 處置 | 更新處 |
|------|------|--------|
| E1：系統睡眠/App Nap | Phase 0驗證AVAudioRecorder行為。Mitigation: `NSProcessInfo.performActivity` | spec §Phase 0 + §Edge Cases (new) |
| E3：孤兒m4a | 刪歷史項→刪m4a。Retry成功→刪m4a。啟動時掃描清孤兒 | spec §Edge Cases (new) |
| E4：Cmd+R作用域 | P3。UX後續補充即可，不阻塞Phase 0 | 未更新，留UX backlog |

---

## DA所提技術風險處置

| 風險 | 處置 |
|------|------|
| activationPolicy動態切換 | 見P1裁定#4 |
| NSTextView Cmd+F啟用 | P2。EN實作時留意，非Phase 0項 |
| notification點擊導航 | P2。EN早期smoke test，非Phase 0項 |

---

## 已更新文件

- `docs/specs/meeting-transcription.md` — rev 4 (final)
- `docs/handoffs/015_PM_EN_audio-transcription-approved.md` — 補充DA P1裁定表

---

## out

DA四項P1已全數裁定，spec rev 4為final版。Phase 0 spike無阻塞。EN可立即開工。

若DA對裁定有異議，請於本handoff out欄回應。否則視為DA close。

status: RDY
