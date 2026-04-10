---
from: PM
to: EN
pri: P0
status: open
created: 2026-04-10
---

## ctx

Audio Transcription V2 UX設計（rev 2）已審閱通過。Spec已更新至rev 3。EN可立即開始Phase 0 validation spike。

## PM裁定

| 項目 | 裁定 | 理由 |
|------|------|------|
| 歷史上限 | 50筆 | 完成轉寫刪除m4a，50筆文字約5MB，遠低於2GB cap。20筆過於保守 |
| 全局快捷鍵 | `Cmd+Shift+T` | 開啟/聚焦main window。V2.0不可自訂——ship opinionated default |
| Dock策略 | `.accessory` ↔ `.regular` | 開window顯、關window隱。macOS慣例。接受 |

## Phase 0 spike指令

1. **時限：5天。** 純驗證，無UI無架構。
2. **六項測試見spec §Phase 0。** 全部需pass，否則V2取消或縮範圍。
3. **關鍵exit criteria：**
   - 處理速度 ≤ 2x real-time（M1 Pro）
   - Chunk stitching < 5% sentence-break errors
   - RAM < model baseline + 500MB
   - m4a decode pipeline可行
4. **交付物：** 一份benchmark report + 建議chunk策略 + go/no-go判定。

## DA最終審查裁定（rev 4補充）

DA handoff 016 LGTM，四項P1已由PM裁定。Spec已更新至rev 4。

| DA P1 | PM裁定 | EN行動 |
|-------|--------|--------|
| 歷史上限20 vs 50矛盾 | **50筆已定。** 2GB cap僅含m4a錄音文件，transcript文字不計 | 無需行動，spec已更新 |
| .ogg decode測試缺失 | **加入Phase 0 spike。** 若AVFoundation不支持且依賴不可接受 → 移除.ogg | Phase 0增加一行：.ogg decode pipeline pass/fail |
| 測試音頻文件來源 | **EN自行準備。** 使用LibriSpeech (EN) + AISHELL (ZH)公開數據集 | Day 1前備妥20個文件 |
| activationPolicy切換風險 | **Phase 0加informal validation。** 若問題嚴重 → 備選：始終`.regular` | Phase 0增加一行：activationPolicy switching驗證 |

**額外Phase 0測試項（已加入spec rev 4）：**
- System sleep / App Nap下AVAudioRecorder行為驗證
- 孤兒m4a防護邏輯（spec §Edge Cases已定義規則）

## 不需等待之事

- UX設計已完成並通過——Phase 0無需任何UI
- DA挑戰已全部回應——無open blocker
- **Spec rev 4（final）已含所有架構決策及邊緣案例——EN可直接參照**

## Phase 0之後

Spike通過 → EN寫handoff回PM，附benchmark結果。PM填入success metrics，開Phase 1。
Spike失敗 → EN寫handoff回PM，附失敗原因。PM決定縮範圍或取消V2。

## refs

- `docs/specs/meeting-transcription.md` — spec rev 4（final，DA P1全解）
- `docs/design/audio-transcription-ux.md` — UX rev 2（已批准）
- `docs/handoffs/014_UX_PM_main-window-revision.md` — UX handoff（已審閱）

## out

Phase 0 spike代碼完成。見 `docs/handoffs/018_EN_PM_phase0-spike-code.md`。
所有四個文件已寫入磁盤。status: RDY
