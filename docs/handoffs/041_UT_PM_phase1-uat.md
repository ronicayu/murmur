---
from: UT
to: PM
pri: P1
status: done
created: 2026-04-10
---

## ctx

吾為Input V1語音輸入之日常使用者。每日以voice input撰文、回信。今觀V2新增Audio Transcription，以用者之目試之。以下為八題之structured feedback。

## out

### 1. 第一印象 — Menu Bar → Main Window

觀popover底部「Open Transcription」一鍵，尚算醒目。waveform icon語義明確，知其為音頻相關。

然有一惑：**吾初以為此app僅menu bar工具也**。忽現一完整window，心中略異。sidebar + main area之佈局，與V1 popover之輕量感判若兩物。非壞事，然需心理調適。

idle狀態之Record/Upload雙卡片，一目了然。「on-device」二字甚好，安心。

**Severity: minor** — 初見之認知落差。用久自適。

---

### 2. 錄音流程 — 30分鐘團隊meeting

流程清晰：Record → 見計時器與波形 → Stop → 確認頁 → Start Transcription。五步而已。

**善者：**
- 計時器monospaced字體，讀之舒適
- 剩餘時間與磁盤空間皆見，安心
- 2小時cap自動停止，無需自憂

**惑者：**
- Input device下拉在錄音畫面。吾欲錄會議，理應**先選mic再錄**。若已按Record方知mic非所欲，須stop重來乎？抑或錄音中可切換？**spec未明**。
- 錄音按Record後，voice input即暫停。然吾尚未開始transcription，僅在錄音耳。**錄音階段何須暫停voice input？** 模型未載入，無資源競爭。此為過度保守。

**Severity:**
- Input device切換時機不明 — **major**
- 錄音階段即暫停voice input — **major**（見第7題詳論）

---

### 3. 上傳流程 — 同事發來之m4a

拖拽至main area，驗證通過，見確認頁。流程極短：拖入 → 確認 → 開始。三步。

**善者：**
- 拖拽區域覆蓋整個main area，不必精確瞄準
- 格式提示「.mp3 .m4a .caf .ogg」清楚
- Est. time以區間顯示，不造偽精確之期待

**惑者：**
- .wav不支持。同事錄音若為.wav，吾需自行轉檔。spec言「deferred due to disk footprint」，然上傳模式不佔額外磁盤——**用者拖入.wav被拒，必感困惑**。
- 拖拽多文件僅取第一個，無提示。應告知「Only one file at a time」。

**Severity:**
- .wav不支持上傳模式 — **major**（常見格式，拒之失用戶信任）
- 多文件拖拽無提示 — **minor**

---

### 4. 等待體驗 — 30分鐘約30分鐘

此為全功能最薄弱之環節。

**善者：**
- Progress bar + segment info（「Processing segment 11 of 17」）令吾知非卡死
- 區間ETA不造偽精確
- 窗口可關閉，background繼續，notification通知完成——此甚善

**痛者：**
- **30分鐘等待，畫面僅一progress bar**。無事可做。不可預覽已完成之segment。不可做他事。吾必切至他處，30分鐘後回來。
- 等待期間voice input暫停。30分鐘不能用voice input。**此乃全功能最大之痛。**（詳見第7題）
- Queue max 1。若有兩段錄音需轉寫，須等第一段完畢方可排第二段。一小時之空窗。

**Severity:**
- 無partial preview — **nice-to-have**（deferred可接受，然長遠必需）
- 30分鐘voice input不可用 — **blocker**（詳見第7題）
- Queue max 1 — **minor**（V2.0可接受，然用戶必問）

---

### 5. 結果使用 — Copy All → Slack

Copy All → paste至Slack，可用。Cmd+C快捷鍵在結果頁直接copy all，甚便。Export .txt亦有。Cmd+F搜尋亦可。

**缺者：**
- **無timestamp**。一小時之meeting transcript，吾欲找「某人說某事」之時刻，純文字流中無從定位。知timestamps已deferred，然此為plain transcript工具之核心痛點。
- 無speaker label。多人會議之transcript，不知誰說何話。亦知deferred，然每次paste至Slack皆需手動標註speaker，甚煩。
- Copy All之「Copied!」反饋1.5秒，善。然paste至Slack後格式為純文字單段。**無段落分隔**之transcript，讀之甚苦。spec未言chunk間是否插入換行。

**Severity:**
- 無timestamp — **major**（plain transcript之基本期待）
- 無speaker diarization — **nice-to-have**（知需另一model，可defer）
- 段落/換行不明 — **major**（若全文為單段，不可用）

---

### 6. 歷史管理 — 一月後尋舊稿

Sidebar按日期分組（Today / Yesterday / MMM d / Earlier），50筆上限。

**惑者：**
- **無搜尋**。50筆歷史，僅見首50字預覽。一月後欲尋某會議之transcript，須逐一點開閱讀。此為**不可接受之體驗**。
- 分組僅至「Earlier」。一月前之transcript皆歸入「Earlier」一堆。無月份分組。
- 50筆是否足夠？吾每週約3-4次會議，50筆約三個月。尚可。然無搜尋則50筆與5筆無異——皆須逐一翻找。

**Severity:**
- 無歷史搜尋 — **blocker**（50筆無搜尋 = 不可管理）
- 「Earlier」分組過粗 — **minor**

---

### 7. Voice Input衝突 — 核心痛點

**此為全評估之最大問題。**

吾每日依voice input工作。轉寫30分鐘音頻 = voice input暫停30分鐘。更甚者：**錄音階段亦暫停**。30分鐘meeting recording + 30分鐘transcription = **一小時不能用voice input**。

此非minor inconvenience。此為吾之主要輸入方式被奪一小時。

**具體場景：**
- 會議中吾錄音（voice input暫停）。會議結束，欲以voice input寫meeting follow-up email。不能。須等轉寫完畢。
- 上傳同事錄音轉寫。轉寫期間欲以voice input回Slack訊息。不能。

**根本問題：** spec言「transcription and voice input cannot run concurrently」，理由為模型共用。然**錄音階段無需模型**——僅AVAudioRecorder錄音耳。錄音時暫停voice input，無技術理由。

**建議：**
1. 錄音階段不暫停voice input。僅transcription processing階段暫停。
2. 若技術上確須全程暫停，**必須在Record按鈕處即告知**，非暫停後方知。

**Severity: blocker** — 每日voice input使用者不可接受一小時之功能中斷。此將令吾不敢使用transcription功能。

---

### 8. 整體評價 — 與MacWhisper/Otter對比

**殺手級特性：**
- **零雲端依賴**。公司內部會議、HR對話、法務討論——凡不可上傳之音頻，Input為唯一選擇（除MacWhisper）。
- **已有模型，零額外下載**。MacWhisper須另下載Whisper模型。Input用戶開箱即用。
- **WER 0.59%**。準確度驚人。若production亦能近此水準，遠勝Whisper。

**與MacWhisper比：**
- MacWhisper有timestamp、有段落、有多格式export。Input皆無。
- MacWhisper不佔voice input。Input佔之。
- 然MacWhisper須另裝，另下載模型。Input一體。

**與Otter比：**
- Otter雲端，隱私不可控。Input完全本地。此為真差異。
- Otter有speaker label、summary、action items。Input皆無。然spec明言非meeting intelligence工具，可接受。

**結論：** 對已用Input之voice input使用者，此功能之value proposition極強——**前提是voice input衝突問題解決**。若一小時不能用voice input，吾寧可另裝MacWhisper。

---

## Structured Feedback Summary

| # | Issue | Severity | 章節 |
|---|-------|----------|------|
| 1 | 錄音階段暫停voice input無技術必要 | **blocker** | 7 |
| 2 | 歷史無搜尋，50筆不可管理 | **blocker** | 6 |
| 3 | 段落/換行規則未定義，恐全文為單段 | **major** | 5 |
| 4 | .wav上傳不支持（上傳模式無磁盤理由） | **major** | 3 |
| 5 | Input device切換時機不明 | **major** | 2 |
| 6 | 無timestamp（plain transcript基本期待） | **major** | 5 |
| 7 | 多文件拖拽無提示 | **minor** | 3 |
| 8 | 「Earlier」歷史分組過粗 | **minor** | 6 |
| 9 | V1→V2認知落差（menu bar→window） | **minor** | 1 |
| 10 | Queue max 1 | **minor** | 4 |
| 11 | Speaker diarization | **nice-to-have** | 5 |
| 12 | Partial preview during transcription | **nice-to-have** | 4 |

**Blocker 2項須於Phase 1解決，否則功能不可ship。Major 4項強烈建議Phase 1處理。**

## refs

- @UX/flow#audio-transcription — docs/design/audio-transcription-ux.md
- @PM/spec#meeting-transcription — docs/specs/meeting-transcription.md
- @DA/challenge#013 — docs/handoffs/013_DA_UX_flow-challenge.md
