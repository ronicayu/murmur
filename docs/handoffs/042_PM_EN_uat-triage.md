---
from: PM
to: EN
pri: P0
status: REQ
created: 2026-04-10
---

## ctx

UT完成Phase 1 UAT（041）。PM裁定如下。Spec已更新至rev 9。

## out

### 必修（P0）— B1 fix: 錄音期間voice input不再暫停

**問題：** 現行實現於錄音開始即pause voice input。錄音僅用AVAudioRecorder，不載模型，無資源競爭。用戶一小時不能voice input，不可接受。

**改為：**
- 錄音期間：voice input正常可用
- 用戶點Stop後，確認頁按「Start Transcription」時才pause voice input
- 轉寫完成或cancel後立即resume

**影響範圍：** `VoiceInputCoordinator`（或等效）之pause trigger須從record-start改為transcription-start。Spec user story #2、#9、constraint #10已更新。

---

### 必修（P1）— 歷史搜索

**問題：** 50筆歷史無搜索 = 不可管理。UT判blocker，PM降為P1（非data loss），但V2.0必須有。

**實現：**
- Sidebar頂部加搜索欄（NSSearchField或SwiftUI equivalent）
- Simple string match against transcript text
- In-memory filter，50筆無需indexing
- 即時過濾sidebar列表
- 空query顯示全部

Spec user story #7已更新。

---

### 必修（P1）— 段落換行

**問題：** 全文為單段plain text，不可讀。

**實現：**
- Chunk拼接時，若前後chunk間silence > 2秒，插入`\n\n`
- Silence duration可從chunk boundary metadata推算（overlap region之gap）
- 若無精確silence data，以chunk boundary為段落分隔點（每30s一段亦遠優於無段落）

Spec user story #3已更新。

---

### 必修（P1）— .wav上傳支持

**問題：** 上傳模式不佔本地磁盤（文件為用戶的），拒絕.wav無理由。

**實現：**
- Upload mode新增`.wav`格式支持
- 驗證邏輯加入.wav
- Decode pipeline：.wav為PCM，AVFoundation原生支持，無需ffmpeg
- 錄音格式仍為m4a，不變

Spec user story #4、scope section已更新。

---

### PUNT（不做）

| Issue | 裁定 | 理由 |
|-------|------|------|
| Input device切換時機 | PUNT V2.1 | V2.0不做device selector |
| Timestamp | 維持PUNT | Spec明確deferred |

## refs

- @PM/spec#meeting-transcription rev 9 — docs/specs/meeting-transcription.md
- @UT/uat#041 — docs/handoffs/041_UT_PM_phase1-uat.md
