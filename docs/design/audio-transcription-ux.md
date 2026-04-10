# Audio Transcription UX Design

**Author:** @UX
**Status:** RDY
**Created:** 2026-04-10
**Revised:** 2026-04-10 (rev 2 — main window architecture)
**Spec:** docs/specs/meeting-transcription.md (rev 2)
**DA challenge:** docs/handoffs/013_DA_UX_flow-challenge.md

---

## Rev 2 變更摘要

創始人裁定：app不再僅為menu bar app。新增main window，承載Audio Transcription全部功能。

| 元件 | 職責 | 變更 |
|------|------|------|
| Menu bar popover | Voice input（V1功能） | 不動。新增「Open Transcription」入口 |
| Main window | 錄音、上傳、轉寫、歷史 | **新增** |
| Dock icon | App可見性 | activationPolicy = .accessory，開window時顯示 |

此修訂同時回應DA `013` handoff之P0/P1/P2全部挑戰項。

---

## 1. 窗口架構

### 1.1 雙窗口模型

```
┌─────────────────────────────────────────────────┐
│                  macOS Menu Bar                  │
│  ┌──────┐                                       │
│  │[mic] │ ← menu bar icon                       │
│  └──┬───┘                                       │
│     │ click                                      │
│     ▼                                            │
│  ┌──────────────┐                                │
│  │  Popover     │   「Open Transcription」         │
│  │  Voice Input │ ─────────────────────────►     │
│  │  (V1不變)    │                          │     │
│  └──────────────┘                          │     │
│                                            ▼     │
│  ┌──────────────────────────────────────────┐    │
│  │  Main Window — Audio Transcription       │    │
│  │  ┌────────┬─────────────────────────┐    │    │
│  │  │Sidebar │  Main Area              │    │    │
│  │  │歷史列表 │  錄音/上傳/轉寫結果     │    │    │
│  │  │        │                         │    │    │
│  │  └────────┴─────────────────────────┘    │    │
│  └──────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
```

### 1.2 開啟main window之入口

| 入口 | 行為 |
|------|------|
| Popover內「Open Transcription」按鈕 | 開啟main window，popover自動關閉 |
| 全局快捷鍵 `Cmd+Shift+T` | 開啟/聚焦main window（可自訂） |
| Dock icon點擊（window已開時） | 聚焦main window |
| macOS notification點擊（轉寫完成） | 開啟main window，導航至對應結果 |

### 1.3 Dock行為

```
activationPolicy = .accessory（預設，menu bar app）

開啟main window時：
  → 暫時切為 .regular
  → Dock顯示app icon
  → app出現於 Cmd+Tab

關閉main window時：
  → 切回 .accessory
  → Dock icon隱藏
  → 從 Cmd+Tab 消失
  → menu bar icon始終在
```

理由：main window開啟時用戶需Dock可見性以切換窗口。關閉後還原為純menu bar app，不佔Dock空間。此為macOS慣例（cf. Bartender, PopClip設定窗口）。

### 1.4 窗口關閉 ≠ 停止作業

- 關閉main window：錄音/轉寫繼續背景運行。Menu bar icon反映狀態。
- 重新開啟main window：恢復至當前session之正確畫面（錄音中、轉寫中、結果頁）。
- 此解決DA B2（popover恢復tab邏輯）——main window始終可見，無popover恢復問題。

---

## 2. Popover（Voice Input — V1不變）

### 2.1 佈局

Popover維持V1之全部功能與佈局，**不加segmented tab**。Rev 1之tab方案廢止。

```
┌─────────────────────────────┐
│  [mic icon] Murmur          │
│  Ready                      │
├─────────────────────────────┤
│                             │
│  (Voice Input 原有內容)      │
│  Language switcher          │
│  Transcription history      │
│                             │
├─────────────────────────────┤
│  [waveform] Open Transcription  │  ← 新增唯一入口
├─────────────────────────────┤
│  Settings · Quit            │
└─────────────────────────────┘
```

### 2.2 「Open Transcription」按鈕

- **位置：** Settings/Quit上方，Divider隔開。
- **樣式：** `MenuRowButtonStyle`（與Settings/Quit同列風格），左側icon `waveform`，文字「Open Transcription」。
- **尺寸：** 全寬，高28pt，水平padding 14pt。
- **狀態指示：** 若有active transcription session（錄音中/轉寫中），按鈕右側顯示小紅點(8pt)或進度百分比（`.caption2`）。
- **快捷鍵：** `Cmd+2`。

### 2.3 Popover尺寸

- 固定260pt寬（V1不變）。不再有340pt寬度切換。
- 高度依Voice Input內容自適應（V1行為不變）。

### 2.4 轉寫中之Voice Input tab

Voice input被暫停時，popover顯示：

```
┌─────────────────────────────┐
│  [mic icon] Murmur          │
│  Voice input paused         │  ← status變為paused
├─────────────────────────────┤
│                             │
│  ┌───────────────────────┐  │
│  │ ⚠ Transcription in    │  │
│  │   progress             │  │
│  │   [View Progress →]    │  │
│  └───────────────────────┘  │
│                             │
│  (其餘Voice Input內容灰顯)  │
│                             │
├─────────────────────────────┤
│  [waveform] Open Transcription  │
├─────────────────────────────┤
│  Settings · Quit            │
└─────────────────────────────┘
```

- banner背景`systemOrange.opacity(0.1)`，文字`systemOrange`。
- 「View Progress」導向main window。
- Voice input hotkey無反應，floating pill顯示「Voice input paused」1.5秒（僅首次，此後不重複——回應DA B7）。

---

## 3. Main Window — 佈局

### 3.1 窗口規格

| 屬性 | 值 |
|------|-----|
| 最小寬度 | 640pt |
| 最小高度 | 480pt |
| 預設寬度 | 780pt |
| 預設高度 | 560pt |
| 最大寬度 | 不限 |
| 最大高度 | 不限 |
| 標題列 | macOS standard window chrome，標題「Audio Transcription」 |
| 樣式 | `.titled`, `.closable`, `.resizable`, `.miniaturizable` |
| 記憶位置 | NSWindow.FrameAutosaveName，跨session保持 |

### 3.2 Sidebar + Main Area

```
┌─ Audio Transcription ──────────────────────────────────┐
│ ┌──────────────┬───────────────────────────────────────┐│
│ │   Sidebar    │        Main Area                      ││
│ │   200pt      │                                       ││
│ │              │                                       ││
│ │ ┌──────────┐ │                                       ││
│ │ │ + New    │ │                                       ││
│ │ └──────────┘ │                                       ││
│ │              │                                       ││
│ │ ── Today ── │                                       ││
│ │ ● Recording  │                                       ││
│ │   01:23:45   │                                       ││
│ │              │                                       ││
│ │ ✓ 2:34 PM   │                                       ││
│ │   So I think │                                       ││
│ │              │                                       ││
│ │ ── Yester ──│                                       ││
│ │ ✓ 3:15 PM   │                                       ││
│ │   The quart. │                                       ││
│ │              │                                       ││
│ │              │                                       ││
│ │              │                                       ││
│ │ ┌──────────┐ │                                       ││
│ │ │⚙Settings │ │                                       ││
│ │ └──────────┘ │                                       ││
│ └──────────────┴───────────────────────────────────────┘│
└────────────────────────────────────────────────────────┘
```

### 3.3 Sidebar

| 元素 | 規格 |
|------|------|
| 寬度 | 200pt，可拖拽調整（min 160pt, max 280pt） |
| 背景 | `.sidebar`（macOS vibrancy material） |
| 「+ New」按鈕 | 頂部，全寬，accent color text，icon `plus.circle`。點擊→main area顯示idle狀態 |
| 歷史分組 | 按日期分組：Today / Yesterday / MMM d / Earlier |
| 歷史項 | 第一行：時間(h:mm a) + 時長(mm:ss)。第二行：首50字預覽，`.caption`，`secondary` |
| Active session | 紅色圓點 + 「Recording」或進度百分比 + 「Transcribing」。置頂，不按日期分組 |
| 選中態 | macOS standard list selection（accent color背景） |
| 右鍵選單 | Delete / Export .txt / Copy All |
| 滑動刪除 | 左滑紅色Delete |
| 歷史上限 | 50筆（DA Q4建議，待PM確認2GB cap計算範圍）|
| 底部Settings | icon `gearshape`，開啟Transcription設定（輸入設備、存儲管理等） |

### 3.4 Main Area — 狀態機

Main area依當前狀態顯示不同內容：

```
[Idle] ──點擊Record──→ [Recording] ──Stop──→ [Confirm] ──Start──→ [Transcribing] ──完成──→ [Result]
  │                                              ↑                        │
  ├──點擊Upload────→ [Validate] ──通過──→ [Confirm]                       │
  │                      │                                                │
  │                    失敗→ Error inline → [Idle]                        │
  │                                                                       │
  ├──點擊歷史項────→ [Result]（歷史模式）                                   │
  │                                                                       │
  └←──────────「+ New」或完成後──────────────────────────────────────────────┘
```

---

## 4. Main Area — 各狀態畫面

### 4.1 Idle狀態

用戶開啟main window或點擊「+ New」所見。

```
┌───────────────────────────────────────────────────┐
│                                                   │
│                                                   │
│         ┌─────────────────────────────┐           │
│         │  [mic.circle]  Record Audio │           │
│         │  Tap to start recording     │           │
│         └─────────────────────────────┘           │
│                                                   │
│         ┌─────────────────────────────┐           │
│         │  [doc.badge.plus]           │           │
│         │  Upload Audio File          │           │
│         │  .mp3 .m4a .caf .ogg       │           │
│         │  < 2hr · on-device          │           │
│         └─────────────────────────────┘           │
│                                                   │
│         Drop audio file here                      │
│                                                   │
└───────────────────────────────────────────────────┘
```

**元素：**

| 元素 | 規格 |
|------|------|
| Record卡片 | 寬320pt max，高72pt，圓角10pt，背景`secondarySystemFill`，hover → `tertiarySystemFill`，居中 |
| Upload卡片 | 同上。支持拖拽，拖拽hover時border變accent color 2pt虛線 |
| 格式提示 | `.caption`，`tertiary`。含「on-device」（DA Q5建議，替代長句privacy promise） |
| 拖拽區域 | 整個main area皆為drop zone。拖入時全區域顯示虛線邊框 + 「Drop audio file」 |
| 首次使用提示 | 無。卡片自明（DA Q5裁定） |

### 4.2 錄音中

```
┌───────────────────────────────────────────────────┐
│                                                   │
│              ◉ Recording                          │
│              01:23:45                              │
│              ━━━━━━━━━━━━━━━━ (waveform)          │
│                                                   │
│   Input device: MacBook Pro Mic            [v]    │
│                                                   │
│   Remaining: 36:15 · 142 MB free                  │
│                                                   │
│              [ ■ Stop Recording ]                 │
│                                                   │
│   ⚠ Voice input paused                           │
│                                                   │
└───────────────────────────────────────────────────┘
```

**元素：**

| 元素 | 規格 |
|------|------|
| 紅色圓點 | 8pt，`symbolEffect(.pulse)`，與menu bar icon聯動 |
| 計時器 | `.system(.title, design: .monospaced)`，居中 |
| 波形 | audio level bar（8段），高24pt，accent color |
| Input device | `.caption`，下拉選擇 |
| 剩餘時間 | 2hr cap倒計時 + 磁盤剩餘。`.caption2`，`tertiary` |
| Stop按鈕 | 寬240pt，高44pt，紅色填充，白色文字+方形stop icon，居中 |
| 暫停提示 | `.caption2`，`systemOrange`，底部。僅此一處顯示（回應DA B7精簡） |

**磁盤空間監控：** 同rev 1（每30秒更新，< 500MB橙色，< 200MB自動停止）。

**2小時到達：** 自動停止，過渡至確認。

**窗口關閉時：** 錄音繼續。Menu bar icon保持`record.circle` pulse。重新開啟window恢復至錄音畫面。

### 4.3 錄音停止 → 轉寫確認

```
┌───────────────────────────────────────────────────┐
│                                                   │
│   Recording complete                              │
│                                                   │
│   Duration:       01:23:45                        │
│   File size:      68 MB                           │
│   Est. time:      ~3–5 min                        │
│                                                   │
│                                                   │
│        [Discard]       [Start Transcription]      │
│                                                   │
└───────────────────────────────────────────────────┘
```

**元素：**

| 元素 | 規格 |
|------|------|
| Est. time | 顯示為區間（DA B3建議）。基於Phase 0 benchmark ratio ± 方差。若ratio不穩定，顯示「a few minutes」 |
| Discard | plain text button，`systemRed`。點擊後刪除m4a，恢復voice input，回idle |
| Start Transcription | accent color filled button，`rounded-lg`，高36pt |

**注意：** 此頁不再重複「Voice input will pause during transcription」——voice input已在錄音開始時暫停，無需重申（DA B7精簡）。

### 4.4 上傳流程

#### 4.4.1 文件選擇

二入口：
1. 點擊Upload卡片 → NSOpenPanel（filter: .mp3, .m4a, .caf, .ogg）
2. 拖拽文件至main area

#### 4.4.2 文件驗證

| 檢查 | 失敗處理 |
|------|---------|
| 格式非 .mp3/.m4a/.caf/.ogg | inline error：「Unsupported format. Use .mp3, .m4a, .caf, or .ogg.」 |
| 時長 > 2hr | inline error：「File exceeds 2-hour limit (actual: 2:34:12).」 |
| 無法讀取/損壞 | inline error：「Cannot read audio file.」 |
| 磁盤 < 1GB | inline error：「Not enough disk space.」 |

Inline error樣式：卡片下方，`systemRed`文字，`caption`字體，icon `exclamationmark.triangle`。3秒後fade out。

#### 4.4.3 文件確認

```
┌───────────────────────────────────────────────────┐
│                                                   │
│   Ready to transcribe                             │
│                                                   │
│   [doc.fill] meeting-notes.m4a                    │
│   Duration:       00:47:23                        │
│   Est. time:      ~1–3 min                        │
│                                                   │
│   ⚠ Voice input will pause during transcription.  │
│                                                   │
│         [Cancel]       [Start Transcription]      │
│                                                   │
└───────────────────────────────────────────────────┘
```

- voice input暫停提示：此為決策點，保留（DA B7裁定位置1有決策意義）。
- 樣式：`.caption`，`systemOrange`，無背景色。簡潔單行。
- Est. time：同4.3，顯示區間。

### 4.5 轉寫中

錄音模式與上傳模式共用：

```
┌───────────────────────────────────────────────────┐
│                                                   │
│              Transcribing...                      │
│                                                   │
│   ████████████████░░░░░░░░░░  62%                 │
│   About 1–2 min remaining                         │
│                                                   │
│   Processing segment 11 of 17                     │
│                                                   │
│              [ Cancel ]                           │
│                                                   │
│   ⚠ Voice input paused                           │
│                                                   │
└───────────────────────────────────────────────────┘
```

**元素：**

| 元素 | 規格 |
|------|------|
| Progress bar | 寬度max 400pt，高4pt，圓角2pt，accent color。determinate |
| 百分比 | `.body`，右對齊於progress bar |
| 剩餘時間 | **區間格式**：「About 1–2 min remaining」（DA B3建議）。永不顯示精確秒數。最後段完成前最小值「< 1 min」 |
| Segment info | `.caption2`，`tertiary` |
| Cancel | plain text button，`systemRed` |
| 暫停提示 | `.caption2`，`systemOrange`，底部（DA B7核心位置2） |

**進度計算：** `完成segments / 總segments`。若已處理segment之速度標準差 > 20%，自動切換為indeterminate spinner + 「Transcribing... this may take a few minutes.」（DA B3放寬觸發條件）。

**Cancel行為（含DA B6表格 + DA Q3確認流程）：**

點擊Cancel後顯示inline確認：

```
┌───────────────────────────────────────┐
│  Cancel transcription?                │
│  Progress will be lost (62% done).    │
│                                       │
│      [Keep going]   [Cancel anyway]   │
└───────────────────────────────────────┘
```

確認後：
1. 停止轉寫pipeline
2. 丟棄partial result
3. 刪除臨時文件（含m4a若為錄音模式）
4. 恢復voice input
5. 回idle

### 4.6 轉寫結果

Main window之結果頁——此為rev 2核心改善，解決DA B1（280pt popover內讀萬字文本之問題）。

```
┌───────────────────────────────────────────────────┐
│  Transcription complete                           │
│  00:47:23 · English detected · Apr 10, 2:34 PM   │
│                                                   │
│  ┌───────────────────────────────────────────┐    │
│  │                                           │    │
│  │ So I think the main issue is that we      │    │
│  │ need to reconsider the approach to the    │    │
│  │ API layer. The current design puts too    │    │
│  │ much pressure on the client side and we   │    │
│  │ should probably move more logic to the    │    │
│  │ server.                                   │    │
│  │                                           │    │
│  │ I agree. Let me pull up the metrics from  │    │
│  │ last quarter. The p95 latency on the      │    │
│  │ client was 2.3 seconds, which is way      │    │
│  │ above our target...                       │    │
│  │                                           │    │
│  │ (scrollable, selectable, full height)     │    │
│  │                                           │    │
│  └───────────────────────────────────────────┘    │
│                                                   │
│  ┌──────────────────────────────────────────┐     │
│  │ [doc.on.doc] Copy All    [Cmd+C]        │     │
│  │ [square.and.arrow.up] Export .txt [Cmd+S]│     │
│  │ [arrow.counterclockwise] New     [Cmd+N]│     │
│  └──────────────────────────────────────────┘     │
│                                                   │
└───────────────────────────────────────────────────┘
```

**元素：**

| 元素 | 規格 |
|------|------|
| Header | 時長 + 偵測語言 + 日期時間，`.caption`，`secondary` |
| 文本區域 | `NSTextView`（只讀），fill available height（非fixed 280pt），可滾動可選取。`.system(.body)` |
| Copy All | 複製全文至clipboard。按下後文字變「Copied!」1.5秒。`Cmd+C` |
| Export .txt | NSSavePanel，預設檔名「Transcription YYYY-MM-DD HH-mm.txt」。`Cmd+S` |
| New | 回idle，開始新session。`Cmd+N` |

**文本區域改善（vs rev 1 popover）：**
- 高度隨窗口resize自適應（非fixed 280pt）
- 預設780pt寬窗口下，可見約30行（vs popover 13行）
- 支持`Cmd+F`文內搜尋（NSTextView原生）
- 不再需要「在TextEdit中開啟」——main window自身即提供足夠閱讀空間

**Voice input恢復：** 轉寫完成時voice input自動恢復。結果頁無暫停提示。

### 4.7 歷史模式結果頁

從sidebar點擊歷史項進入。與4.6相同佈局，差異：

| 差異 | 說明 |
|------|------|
| Header | 顯示歷史日期，非「Transcription complete」 |
| 「New」按鈕 | 標籤改為「← Back」（DA B5語義區分），返回sidebar選中態。快捷鍵`Esc` |
| Sidebar | 保持可見，當前項高亮 |

---

## 5. 文件命運表（DA B6 — P0回應）

三種終止情境之文件處置，統一定義：

| 終止情境 | m4a錄音文件 | 歷史記錄 | Voice input |
|---------|------------|---------|-------------|
| 用戶主動Cancel | 刪除 | 不建立 | 立即恢復 |
| 轉寫失敗/crash | 保留 | 建立，狀態「Failed — tap to retry」 | 立即恢復 |
| 轉寫完成 | 刪除（文字transcript已存） | 建立，正常顯示 | 立即恢復 |
| 用戶Discard（錄音後不轉寫） | 刪除 | 不建立 | 立即恢復 |

**失敗歷史項之UI：**
- Sidebar中顯示：`⚠ Failed · h:mm a`，`systemRed`文字
- 點擊後main area顯示：「Transcription failed. [Retry]」+ 錯誤原因
- Retry使用保留之m4a重新轉寫
- 用戶可右鍵刪除失敗項（同時刪除保留之m4a）

---

## 6. Menu Bar Icon狀態（DA B4 — P2回應）

採納DA建議，簡化為三態：

| 狀態 | Icon | 說明 |
|------|------|------|
| Idle | `mic.fill` | voice input就緒，或無active session |
| Active | `mic.fill` + pulse | voice input recording中 **或** audio recording中 |
| Processing | `waveform` + pulse | 轉寫處理中 |

**變更理由：**
- Rev 1有五態（idle / voice recording / audio recording / transcribing / complete），16pt menu bar icon下難以區分audio recording之`record.circle`與voice recording之`mic.fill`+pulse。
- `checkmark.circle`短暫態（2秒）廢止——macOS notification已覆蓋此需求。
- Active態合併voice recording與audio recording——兩者不可能並發（voice input exclusivity約束），故無混淆風險。

---

## 7. Voice Input暫停提示策略（DA B7 — P2回應）

Rev 1有七處提示。Rev 2精簡為二處核心位置 + 一處條件觸發：

| 位置 | 提示 | 理由 |
|------|------|------|
| 上傳確認頁（§4.4.3） | `⚠ Voice input will pause during transcription.` | 決策點，用戶需知副作用 |
| 轉寫中畫面底部（§4.5） | `⚠ Voice input paused` | 持續狀態提醒 |
| Floating pill（hotkey觸發時） | 「Voice input paused」1.5秒 | 條件觸發：僅當session首次按hotkey時顯示一次，此後不重複 |

**廢止之位置：**
- 錄音確認對話框（§2.2.1）——錄音開始前voice input即暫停，用戶已在操作transcription tab，暫停為隱含前提
- 錄音中畫面底部——錄音中畫面已有紅色Recording指示，voice input暫停為必然，重複無意義
- 轉寫確認畫面（錄音後）——voice input已在錄音時暫停，此處重複
- Voice Input tab灰色banner——保留（§2.4已定義），但此為popover內容，非main window提示

**「Don't show again」checkbox：** 廢除（DA Q2裁定）。所有保留之提示皆為permanent，不可關閉。

---

## 8. 交互細節

### 8.1 動畫與過渡

| 過渡 | 動畫 |
|------|------|
| Main window開啟 | macOS standard window animation |
| Idle → Recording | crossfade, 200ms |
| Recording → Confirm | crossfade, 150ms |
| Confirm → Transcribing | crossfade, 150ms |
| Transcribing → Result | slide from right, 250ms |
| Result → Idle (New) | slide from left, 250ms |
| Sidebar選擇切換 | crossfade main area, 150ms |
| Error inline | fade in 150ms, fade out 300ms |
| Drag hover | border color transition 100ms |
| Cancel確認overlay | fade in 150ms |

### 8.2 快捷鍵

| 快捷鍵 | 作用域 | 作用 |
|---------|--------|------|
| `Cmd+Shift+T` | 全局 | 開啟/聚焦main window |
| `Cmd+N` | Main window | 新session（回idle） |
| `Cmd+R` | Main window (idle) | 開始錄音 |
| `Cmd+R` | Main window (recording) | 停止錄音 |
| `Cmd+C` | 結果頁 | Copy All |
| `Cmd+S` | 結果頁 | Export .txt |
| `Cmd+F` | 結果頁 | 文內搜尋 |
| `Esc` | 轉寫中 | 觸發Cancel確認 |
| `Esc` | 歷史結果頁 | 返回（← Back） |
| `Cmd+2` | Popover | Open Transcription |
| `Cmd+,` | Main window | 開啟Settings |

### 8.3 窗口關閉 vs 背景運行

| 情境 | 行為 |
|------|------|
| 錄音中關閉window | 錄音繼續。Menu bar icon `mic.fill`+pulse。重開window恢復錄音畫面 |
| 轉寫中關閉window | 轉寫繼續。Menu bar icon `waveform`+pulse。重開window恢復進度 |
| 轉寫完成，window已關閉 | macOS notification：「Transcription complete — 47:23 of audio.」點擊→開啟window至結果頁 |
| Idle關閉window | 正常關閉。Dock icon隱藏。Menu bar icon回idle |

---

## 9. 邊緣案例

### 9.1 磁盤空間

| 情境 | 處理 |
|------|------|
| 啟動錄音時 < 1GB free | 拒絕，inline error |
| 錄音中 < 200MB | 自動停止，彈確認「Recording stopped — disk almost full. Transcribe this recording?」 |
| 歷史佔用接近2GB（80%即1.6GB） | Sidebar底部黃色banner：「Storage almost full (1.6 / 2 GB). Delete old transcriptions.」 |
| 歷史佔用 = 2GB | 拒絕新錄音/上傳。Idle狀態卡片灰顯+提示 |

### 9.2 格式與文件

| 情境 | 處理 |
|------|------|
| 不支持格式 | inline error，列出支持格式 |
| 損壞文件 | 「Cannot read audio file. The file may be corrupted.」 |
| 0秒時長 | 「Audio file appears to be empty.」 |
| > 2hr | 顯示實際時長，提示上限 |
| 拖拽多個文件 | 只取第一個，忽略其餘 |

### 9.3 轉寫失敗

| 情境 | 處理 |
|------|------|
| 模型加載失敗 | 「Transcription engine failed to start. Try again or restart Input.」+ Retry |
| 處理中crash | 建立失敗歷史項（§5），保留m4a供Retry |
| 記憶體不足 | 「Not enough memory. Close other apps and try again.」 |
| 超時（`audio_duration * 3`） | 建立失敗歷史項，提示retry |

### 9.4 並發與衝突

| 情境 | 處理 |
|------|------|
| 轉寫中嘗試voice input hotkey | 無反應。Floating pill「Voice input paused」（session首次限定） |
| 錄音中嘗試上傳 | 不可能——UI已為錄音畫面 |
| Voice input recording中開啟main window | main window可開啟，但idle狀態顯示「Voice input active — finish first」灰色提示 |
| App啟動時有失敗歷史項 | Sidebar顯示失敗項，可Retry或刪除 |
| 轉寫queue max 1 | 已有active session時，「+ New」按鈕灰顯，tooltip「Finish current transcription first」 |

### 9.5 空狀態

| 情境 | 顯示 |
|------|------|
| 從未使用Transcription | Sidebar空，僅「+ New」。Main area顯示idle卡片 |
| 歷史已清空 | 同上 |
| Main window開啟但無選中項 | 顯示idle狀態（Record/Upload卡片） |

---

## 10. 視覺方向

### 色彩

與Murmur現有一致，使用macOS system colors：

| 用途 | 顏色 |
|------|------|
| Primary action | System accent color |
| Recording | `systemRed` |
| Warning | `systemOrange` |
| Error | `systemRed` |
| Success | `systemGreen` |
| Voice input paused | `systemOrange` text（無背景色，簡化） |
| Sidebar背景 | `.sidebar` vibrancy |

### 字體

| 用途 | 規格 |
|------|------|
| Window title | macOS system（window chrome） |
| Sidebar section header | `.system(.caption, weight: .semibold)`，`tertiary`，大寫 |
| Sidebar item primary | `.system(.callout)` |
| Sidebar item secondary | `.system(.caption)`，`secondary` |
| 計時器 | `.system(.title2, design: .monospaced)` |
| 正文（結果文本） | `.system(.body)` |
| 輔助文字 | `.system(.caption)` |
| 標籤 | `.system(.caption2)` |

### 間距

| 規格 | 值 |
|------|-----|
| Sidebar水平padding | 12pt |
| Sidebar項目間距 | 2pt（compact list） |
| Main area水平padding | 24pt |
| Main area垂直padding | 20pt |
| 卡片內padding | 16pt |
| 元素間距 | 8pt |
| Section間距 | 16pt |

---

## 11. 完整用戶流程

### 11.1 錄音流程

```
[Open main window]
  │
  ├─ Sidebar「+ New」或 idle狀態
  │
  ├─ 點擊 Record
  │   │
  │   ├─ 磁盤 < 1GB？→ Error inline → 回Idle
  │   │
  │   ├─ 暫停 voice input
  │   ├─ Menu bar icon → active (pulse)
  │   │
  │   └─ [Recording]
  │       │
  │       ├─ Stop / 2hr到達 / 磁盤不足 → 自動Stop
  │       │
  │       └─ [Confirm]
  │           │
  │           ├─ Discard → 刪除m4a → 恢復voice input → Idle
  │           │
  │           └─ Start Transcription
  │               │
  │               ├─ Menu bar icon → processing (waveform pulse)
  │               ├─ Sidebar顯示active session
  │               │
  │               └─ [Transcribing]
  │                   │
  │                   ├─ Cancel（需確認）→ 丟棄 → 恢復voice input → Idle
  │                   ├─ 失敗 → 建立失敗歷史項 → 恢復voice input
  │                   │
  │                   └─ 完成
  │                       │
  │                       ├─ 恢復 voice input
  │                       ├─ Menu bar icon → idle
  │                       ├─ Notification（若window關閉）
  │                       ├─ Sidebar新增歷史項
  │                       │
  │                       └─ [Result]
  │                           ├─ Copy All / Export .txt
  │                           └─ New → Idle
```

### 11.2 上傳流程

```
[Idle]
  │
  ├─ 點擊 Upload 或 拖拽文件
  │   │
  │   ├─ 驗證失敗 → Error inline → Idle
  │   │
  │   └─ [Confirm]（顯示文件資訊 + voice input暫停提示）
  │       │
  │       ├─ Cancel → Idle
  │       └─ Start Transcription → 同錄音流程之 [Transcribing] 起
```

### 11.3 歷史流程

```
[Sidebar]
  │
  ├─ 點擊歷史項 → [Result]（歷史模式）
  │   ├─ Copy All / Export .txt
  │   └─ ← Back → Sidebar
  │
  ├─ 點擊失敗項 → [Failed detail] → Retry 或 Delete
  │
  ├─ 右鍵 → Delete / Export / Copy All
  │
  └─ Settings → 存儲管理
```

---

## 12. DA挑戰回應索引

| DA項目 | 嚴重性 | 處置 | 所在章節 |
|--------|--------|------|---------|
| B2：popover恢復tab邏輯 | P0 | main window始終可見，問題不再存在 | §1.4 |
| B6：失敗後文件命運 | P0 | 定義完整表格 | §5 |
| B1：長文本閱讀體驗 | P1 | main window提供full-height文本區域 | §4.6 |
| B3：ETA準確度 | P1 | 區間顯示 + 放寬indeterminate觸發 | §4.5 |
| Q2：廢除Don't show again | P1 | 已廢除，改permanent提示 | §7 |
| B5：歷史導航 | P1 | sidebar解決sticky問題 + Back語義區分 | §3.3, §4.7 |
| Q3：Cancel確認 | P2 | inline確認顯示進度百分比 | §4.5 |
| B4：icon簡化 | P2 | 三態 | §6 |
| B7：banner精簡 | P2 | 七處→二處核心+一條件 | §7 |
| Q1：固定寬度 | 已解 | main window取代popover，不再有寬度切換問題 | §2.3 |
| Q4：歷史50筆 | 待PM | sidebar支持50筆，2GB cap計算待釐清 | §3.3 |
| Q5：刪除提示文字 | 低 | 改「on-device」subtitle | §4.1 |
