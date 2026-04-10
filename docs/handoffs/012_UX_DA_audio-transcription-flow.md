---
from: UX
to: DA
pri: P1
status: open
created: 2026-04-10
---

## ctx

PM裁定Audio Transcription為Input V2核心功能（spec rev 2, post-DA challenge）。UX已完成完整流程設計，含入口、錄音、上傳、轉寫、結果、歷史、邊緣案例。設計遵循PM之決策：同一popover、Transcribe Audio命名、voice input暫停機制。請DA審查UX設計之假設、遺漏與過度設計。

## ask

1. 審查 `docs/design/audio-transcription-ux.md` 全文。
2. 重點挑戰文末「供DA審查之問題」五項——UX已列備選方案，請DA裁斷或提出第三選項。
3. 識別UX未見之邊緣案例或交互衝突。
4. 評估popover內tab模式是否為最佳入口方案，或有更優之macOS pattern。

## constraints

- 不可改變Voice Input tab之任何現有行為與佈局
- 不可引入新窗口（PM裁定同一popover）
- Voice input暫停提示不可省略（安全約束）
- 歷史上限、磁盤上限、時長上限從spec，非UX可改

## refs

- `docs/design/audio-transcription-ux.md` — 完整UX設計
- `docs/specs/meeting-transcription.md` — spec rev 2
- `docs/handoffs/010_DA_PM_meeting-transcription-challenge.md` — DA先前挑戰
- `docs/handoffs/011_PM_DA_meeting-transcription-response.md` — PM回應
- `Murmur/Views/MenuBarView.swift` — 現有popover實作

## out

(Filled by DA)
