---
from: UX
to: PM
pri: P1
status: LGTM
created: 2026-04-10
---

## ctx

創始人裁定app新增main window。UX已全面修訂`docs/design/audio-transcription-ux.md`至rev 2。此handoff述變更要點與DA挑戰之回應，請PM審閱裁定。

## 變更

### 架構變更

1. **廢止popover內segmented tab方案。** Rev 1之Transcribe tab全部移出popover，遷入獨立main window。
2. **Popover僅保留Voice Input（V1不變）。** 新增「Open Transcription」按鈕為唯一入口。
3. **Main window：sidebar + main area。** sidebar承載歷史列表（解決DA B5導航問題），main area承載全流程。macOS standard window chrome，可調寬高。
4. **Dock行為：** `activationPolicy = .accessory`，開window時暫時顯示Dock icon，關閉後隱藏。

### DA P0回應

| 項目 | 處置 |
|------|------|
| B2：popover恢復tab邏輯 | main window始終可見，問題消解。窗口關閉時作業繼續背景運行，重開恢復畫面 |
| B6：文件命運 | 定義四種終止情境表格（Cancel刪除 / crash保留+建失敗歷史項 / 完成刪除m4a / Discard刪除） |

### DA P1回應

| 項目 | 處置 |
|------|------|
| B1：長文本閱讀 | main window文本區域fill available height，支持Cmd+F搜尋。不再需外部工具 |
| B3：ETA區間 | 改為「About 1–2 min remaining」區間格式。標準差>20%切indeterminate |
| Q2：Don't show again | 廢除checkbox。所有暫停提示permanent |
| B5：歷史導航 | sidebar解決sticky問題。歷史結果頁「New」改「← Back」 |

### DA P2回應

| 項目 | 處置 |
|------|------|
| Q3：Cancel確認 | 加inline確認，顯示進度百分比 |
| B4：icon簡化 | 五態→三態：idle / active(pulse) / processing(waveform) |
| B7：banner精簡 | 七處→二處核心（上傳確認頁 + 轉寫中底部）+ 一條件觸發（hotkey首次） |

### 待PM裁定

1. **歷史上限：** 設計支持50筆（DA建議），但spec寫20筆。2GB cap是否含錄音m4a？若僅含文字transcript，50筆文字約5MB，遠低於cap。請釐清後UX相應調整。
2. **全局快捷鍵 `Cmd+Shift+T`：** 開啟main window。與其他app是否衝突？PM可裁定是否user-configurable。
3. **Dock行為：** accessory → regular切換方案是否acceptable？備選：始終.regular（常駐Dock），但佔位。

## refs

- `docs/design/audio-transcription-ux.md` — rev 2（本次修訂）
- `docs/handoffs/013_DA_UX_flow-challenge.md` — DA挑戰（已全部回應）
- `docs/specs/meeting-transcription.md` — spec rev 2

## out

**PM審閱完成 2026-04-10。LGTM。**

三項裁定：歷史上限50筆（接受）、全局快捷鍵`Cmd+Shift+T`（接受，V2.0不可自訂）、Dock策略accessory（接受）。

Spec已更新至rev 3。已寫handoff `015_PM_EN_audio-transcription-approved.md` 交EN開始Phase 0 spike。
