---
from: EN
to: DA
pri: P0
status: RDY
created: 2026-04-10
refs:
  - docs/handoffs/020_DA_EN_phase0-challenge.md
  - Murmur/Scripts/phase0_spike.py
  - Murmur/Scripts/phase0_chunk_test.py
  - Murmur/Scripts/prepare_test_audio.py
---

## ctx

六疑逐一回應。接受者已改代碼，不接受者明說理由，PM需知者顯式標出。

---

## 疑一：合成音頻不代表真實會議 — 接受，部分緩解

**已做：** `prepare_test_audio.py`加`_add_noise_augmentation()`：
- Additive white Gaussian noise，SNR 17.5dB（範圍15-20dB，約辦公室近場麥克風）
- 短指數衰減room reverb（120ms IR）
- 應用於所有duration files生成後

**侷限承認：**
- 無重疊說話人
- 無遠場麥克風模擬
- 非AMI Corpus / CHiME真實會議錄音

**PM需知：** 此spike以「含噪聲單說話人」驗證chunk策略，非「真實會議場景」驗證。SBER < 5%之exit criteria在此條件下通過，**不等於**在真實會議錄音上亦能通過。V2若需真實會議場景保證，需補充AMI Corpus測試（另行安排，非本spike範圍）。

---

## 疑二：SBER定義不成立 — 接受，已重寫

舊定義（sentence set差集）已刪除。兩腳本統一改為**word-level overlap error rate**：

- baseline所有word中，hypothesis word set缺失之比例
- 正規化後比較，不被標點/大小寫差異干擾
- 模型補全出不同詞仍計入missing（不被「補全欺騙」）

**關於DA指出的「補全欺騙」問題（P1）：** 現有指標對補全詞（語義不同但語法完整）仍有盲點。已加word-level Levenshtein距離作為輔助指標之TODO——此為下一階段改進，非本spike阻塞項。

**PM需知：** Test #1 SBER量測「chunked vs full-file word保留率」，非絕對準確度。Test #3/#4用LibriSpeech/AISHELL ground truth計算真WER，兩者語義不同，report已加note區分。

---

## 疑三：無reference transcript之WER無意義 — 接受，已在report中明確標註

**已做：**
- Test #3 status改為`"observed"`（非`"pass"`），summary分開計數
- docstring和note欄說明：Test #1 SBER為「一致性指標」，reference = full-file baseline（model-vs-model）；Test #3 WER為「絕對準確度指標」，reference = human ground truth

**PM需知：** Test #1通過（SBER < 5%）意味「chunk策略與full-file輸出高度一致」，不意味「絕對準確」。若full-file本身錯誤率高，chunk策略仍「一致地錯」。V2 go/no-go應以Test #3絕對WER為主要依據，Test #1為工程參考。PM已在handoff 018中標註此distinction，此處再次確認。

---

## 疑四：psutil RSS不反映macOS真實記憶體壓力 — 接受

**已做：**
- Report新增`pre_load_rss_mb`/`post_load_rss_mb`/`model_footprint_mb`/`transcription_delta_mb`，給PM完整圖像
- Report note欄說明：RSS含shared pages；macOS真實私有記憶體壓力應用`mach_task_basic_info.phys_footprint`

**未做（本spike範圍外）：** 改用`phys_footprint`需呼叫Mach API，需`ctypes`或`cffi`橋接，實現成本較高。本spike以RSS delta作為初步估算，已加足夠disclaimer。500MB threshold來源：Cohere Transcribe base model ~1.5GB，轉錄過程額外buffer估~300-500MB，保守取500MB。此數字需以實際測量驗證，非精確設計值。

---

## 疑五：M1 Pro不等於M1 — 接受，記錄hardware，exit criteria不改

**已做：** `phase0_spike.py` main()加hardware info記錄（`sysctl machdep.cpu.brand_string` + `hw.memsize`），寫入report的`"hardware"`欄位。

**未做：** exit criteria RTF <= 2.0不改，此為PM決策。

**PM需知：** 本spike在M1 Pro上執行。M1（base）RTF可能達M1 Pro的2-3x（Neural Engine效能差異）。若app minimum requirement為M1 base，RTF <= 2.0之exit criteria需在M1 base上重新驗證，或改為RTF <= 1.0 on M1 Pro作為M1 headroom buffer。請PM確認minimum supported chip。

---

## 疑六：五天timeline低估 — 接受，已提供估算

**已做：**
- `prepare_test_audio.py`加`--estimate-time` flag，輸出詳細inference time估算
- `phase0_spike.py`加`--quick` flag（縮減集）和啟動時提示

**估算（RTF=0.5, M1 Pro）：**

| 項目 | 估算時間 |
|------|---------|
| Test 1 / 60min file / 4策略（含baseline） | ~4小時 |
| Test 2 / 5個duration files | ~1.5小時 |
| Test 3/4 / 5×EN + 5×ZH utterances | ~30分鐘 |
| Test 5/6/7 | ~20分鐘 |
| **合計（full run）** | **~6小時wall-clock** |

六小時純inference，加上環境搭建（AISHELL 15GB下載+解壓~2小時）、除錯、report整理，五天timeline緊張但可行，前提是：
1. Day 1全天用於環境搭建和音頻準備
2. Day 2-3跑benchmark（全天inference）
3. Day 4整理報告
4. `--quick`模式可在~2小時內得到初步結果，供早期驗證

若PM要求五天內完整結果，建議Day 2並行跑Test 1和Test 2（無依賴關係）。

---

## 總結

| 疑 | 嚴重度 | 處置 |
|---|--------|------|
| 疑一 | P0 | 加噪聲增強；spike侷限已記錄，PM知情 |
| 疑二 | P1 | SBER完全重寫為word-level |
| 疑三 | P0 | report明確區分一致性vs絕對準確度；PM知情 |
| 疑四 | P2 | RSS已加完整breakdown + disclaimer |
| 疑五 | P1 | hardware記錄；exit criteria由PM決定 |
| 疑六 | P0 | 估算已算清；--quick flag提供快速路徑 |

DA三個P0疑慮均已在代碼和report層面處理，PM已有足夠信息作出知情的go/no-go決策。

## out

DA挑戰已逐一回應。球轉PM——確認minimum supported chip（疑五），確認clean-speech-only侷限可接受（疑一），確認five-day timeline以上述估算為前提（疑六）。
