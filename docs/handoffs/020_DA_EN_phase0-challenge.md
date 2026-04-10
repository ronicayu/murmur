---
from: DA
to: EN
pri: P0
status: RDY
created: 2026-04-10
refs:
  - docs/handoffs/018_EN_PM_phase0-spike-code.md
  - docs/specs/meeting-transcription.md
  - Murmur/Scripts/phase0_spike.py
  - Murmur/Scripts/phase0_chunk_test.py
  - Murmur/Scripts/prepare_test_audio.py
---

## ctx

讀EN之phase0 spike代碼。不評代碼品質（CR之責），問者乃：此spike能否真正驗證V2可行性？

六疑，逐陳之。

---

## 疑一：合成音頻不代表真實會議

`prepare_test_audio.py` 生成duration文件之法：取LibriSpeech/AISHELL片段，循環拼接（`np.tile(pool, repeats)`）。

LibriSpeech為朗讀體——錄音室收音，無背景噪音，無回音，距麥克風甚近，語速均勻，句句清晰。真實會議錄音則：有空調噪音、鍵盤聲、遠端麥克風、重疊發言之殘響、說話人離麥克風遠近不一。

**問題：** 60min.wav為同一說話人讀書片段之重複拼接。此音頻在clean speech上跑出SBER < 5%，不能推論同一chunk策略在真實會議錄音上亦能過關。spike以此為exit criteria通過——然後V2上線，用戶拿真實會議來跑，SBER遠高於5%。

**挑戰：** exit criteria需以真實或近真實錄音驗證。至少加一組含背景噪音之音頻（可用公開數據集如AMI Corpus，或人工加噪）。純LibriSpeech拼接通過之SBER < 5%，對V2之預測力接近零。

---

## 疑二：Sentence-break error rate定義不成立

`_sentence_break_error_rate()` 之邏輯：

```python
broken = len(full_set - chunked_set)
return broken / len(full_set)
```

以句子集合差計算。此定義有二根本缺陷：

**缺陷A — 對等句測不出邊界截斷。** 若chunk邊界恰在句中截斷「The quick brown fox jumps over the lazy」，模型可能補全為「The quick brown fox jumps」——此仍是完整句子，不在`full_set - chunked_set`之差集內，SBER計為0，實則有資訊丟失。

**缺陷B — 合成音頻無真實句子邊界。** LibriSpeech拼接之60min.wav，每個utterance約5–15秒，拼接點即為句子邊界。chunk以30/60/120秒切割，拼接點之數遠多於chunk邊界數。即使chunk邊界截斷真實語句，SBER因baseline已有大量「完整短句」而被稀釋，分母虛大，分子虛小。

**挑戰：** SBER指標需重新定義。建議改用：chunk邊界附近（±2秒）之word error rate，或以對齊算法（如Smith-Waterman）比對baseline與chunked output之token序列，量化boundary region之token損失率。現行集合差算法可輕易被「模型補全」欺騙。

---

## 疑三：無reference transcript之WER無意義

Test #3 Single-speaker accuracy：`_load_reference_transcripts()` 以`.txt`文件為reference。LibriSpeech utterance確有ground truth。

然Test #1、#2所用之duration文件（5min.wav…120min.wav）為拼接生成，無對應reference transcript。

`test_chunk_strategy()` 以full-file baseline為reference——即以「同一模型不分chunk之輸出」為ground truth，用chunked輸出與之比較。

**問題：** 此非WER，乃「chunked vs full-file之一致性測試」。若模型在full-file上本已出錯，baseline亦含錯，則SBER量測的是「chunk策略是否與full-file犯同樣的錯」，非「chunk策略是否產生正確transcript」。

V2 go/no-go decision之依據，應是絕對準確度，非相對一致性。

**挑戰：** 需有人工標注之reference transcript，或使用有reference之公開長音頻（如TED-LIUM，含完整逐字稿）。若無，Test #1之SBER pass不能作為V2可行性依據，只能作為「chunk策略間比較」之工程參考。PM需知此distinction。

---

## 疑四：psutil RSS不反映macOS真實記憶體壓力

Test #5 memory usage：

```python
rss = proc.memory_info().rss / (1024 * 1024)
```

**問題一 — RSS含shared memory。** macOS上，RSS (Resident Set Size) 包含shared libraries、framework、dyld cache之共享頁。同一進程之RSS在不同run之間可差數百MB，非模型實際佔用之private memory。正確指標應為「physical footprint」（`task_info` MACH_TASK_BASIC_INFO之`phys_footprint`），即系統實際因此進程而增加的記憶體壓力。

**問題二 — delta計算假設baseline穩定。** `baseline_mb = _measure_rss_mb()` 在model load後測一次。若模型load時lazy-load某些weights，baseline偏低，delta虛大；或若OS在baseline測量後回收shared pages，delta虛大。

**問題三 — 500 MB threshold之來源不明。** spec定義`< model_baseline + 500 MB`，但500MB從何而來？若模型本身已佔3GB（Cohere Transcribe為大型模型），再加500MB仍可能觸發macOS memory pressure warning，導致系統swap或OOM kill其他進程。

**挑戰：** 改用`/usr/bin/memory_pressure`或`mach_task_basic_info.phys_footprint`量測。補充：在16GB RAM機器上，同時跑Xcode/Chrome/Slack時，500MB additional RAM是否仍可接受？需端到端場景測試，非isolated benchmark。

---

## 疑五：exit criteria綁定M1 Pro，其他Apple Silicon未定義

Spec明確寫：「Benchmark 5 / 15 / 30 / 60 / 120 min audio files on **M1 Pro 16GB**」。

**問題：** App之hardware requirement為「macOS / Apple Silicon / 16 GB+」（spec §Constraints），非僅M1 Pro。M1（8-core GPU, 低頻寬），M2 Pro（更高throughput），M3 Max（更大unified memory bandwidth）——各代Apple Silicon之Neural Engine效能差距達2–3x。

若spike在M1 Pro上RTF = 1.5（pass），EN以此作go-ahead，用戶在M1（基本款）上實際RTF可能達2.5–3.0，超過2x real-time之cancel threshold。

**挑戰：** 需定義minimum supported chip。若minimum為M1，spike必須在M1上驗證，或M1 Pro結果須加conservative headroom（如RTF < 1.0 on M1 Pro → estimated pass on M1）。現行exit criteria「RTF <= 2.0」無機器型號前提，通過條件不明確。

---

## 疑六：五天時限低估準備成本，真實可用時間不足

EN之spike timeline（隱含於handoff中）：五天完成prepare_test_audio + run benchmark + write report。

逐日審視：

| 日 | 預計工作 | 隱藏風險 |
|----|---------|---------|
| Day 1 | 安裝依賴、跑prepare_test_audio.py | AISHELL下載15GB，網速若50MB/s需5分鐘；然解壓、轉換、resample 15GB tar需1–2小時。LibriSpeech test-clean約346MB，快；但全流程環境搭建（ffmpeg, webrtcvad C extension on arm64）可能佔半天 |
| Day 2 | 跑Tests #1–5 | 120min音頻以RTF=1.5計，單次transcribe需3小時。Test #1跑4種策略×每策略需transcribe全文件baseline + N chunks = 4×(1+chunks)次inference。60min文件若chunk為30s，有120個chunks，加baseline共121次transcribe，每次~45秒 = 90分鐘×4策略 = 6小時 |
| Day 3 | 重跑 / 除錯 / Tests #6–7 | 必然有環境問題 |
| Day 4 | Swift Tests #8–9 + 整理report | activationPolicy測試需手動觀察，非完全自動化 |
| Day 5 | Buffer | 實際為Day 1延誤之補救 |

**核心問題：** Test #1之chunk策略測試，對60min文件跑4種策略，每種策略需transcribe數十至百個chunk——合計inference次數極多，wall clock time可能超過一整天，而非數小時。EN未做此估算。

**挑戰：** EN需提供realistic time estimate：每次inference耗時（秒）× chunk數 × 策略數 × 語言數。若total > 24小時，五天根本不夠，需要：(a) 縮短測試音頻至30min，(b) 限定測試策略為2種，或(c) 延長timeline。今給PM錯誤期望，後患更大。

---

## 建議優先級

| # | 嚴重度 | 建議 |
|---|--------|------|
| 疑一 | P0 | 加至少一組含噪聲/遠場錄音。純LibriSpeech結論無效。 |
| 疑三 | P0 | 明確區分「絕對WER」vs「一致性測試」。PM需知差異再決定go/no-go。 |
| 疑六 | P0 | 算清inference次數，給PM realistic timeline。今日即可算。 |
| 疑二 | P1 | SBER定義需修正，否則指標可被模型補全欺騙。 |
| 疑五 | P1 | 定義minimum supported chip，spike在最低規格機器上驗證。 |
| 疑四 | P2 | RSS改phys_footprint。500MB threshold需有出處。 |

---

## 期待EN之回應

1. 疑一：是否有計劃加真實/含噪聲音頻？若無，承認此spike為「clean speech概念驗證」，非「會議場景驗證」，PM需相應調整go/no-go criteria。
2. 疑三：PM是否已知SBER之reference為model-vs-model而非model-vs-ground-truth？
3. 疑六：請給出estimated total inference time，確認五天timeline可行。

不要求重寫全部代碼——要求EN與PM對spike之侷限達成明確共識，避免以不充分之驗證作出V2 go-ahead之誤判。

## out

挑戰已提。球在EN與PM手中。若EN確認疑一/三/六之侷限已知且PM接受，此spike仍可作有限驗證之用；若否，建議在修正後再行go/no-go評估。
