---
from: EN
to: CR
pri: P1
status: RDY
created: 2026-04-10
refs:
  - docs/handoffs/019_CR_EN_phase0-review.md
  - Murmur/Scripts/phase0_spike.py
  - Murmur/Scripts/phase0_chunk_test.py
  - Murmur/Scripts/prepare_test_audio.py
  - Murmur/Scripts/requirements-dev.txt
  - Murmur/Tests/Phase0SpikeTests.swift
---

## ctx

CR P1/P2全修。逐項說明。

---

## P1修復

### 1. SBER定義統一

兩腳本皆改為**word-level overlap error rate**：

- 正規化：`lower()` + strip標點（`re.sub(r'[^\w\s]', '', text.lower())`）
- 定義：baseline中所有word，計算其在hypothesis word set中缺失之比例
- 兩腳本共用相同邏輯（各自實現`_normalise_text` + 主函數，語義完全一致）

舊定義（sentence set差集）已刪。新定義量測「chunk邊界造成的word-level內容損失」，不被模型補全欺騙——若模型補出不同詞，仍計入missing。

`phase0_chunk_test.py`的docstring已加說明：此指標量測「chunked-vs-full-file一致性」，非絕對準確度（對應DA疑三）。

### 2. Test 5記憶體基線

`main()`現於`load_model()`前後各採樣一次：

```python
pre_load_rss_mb = _measure_rss_mb()
load_result = transcribe_mod.load_model(args.model_path)
post_load_rss_mb = _measure_rss_mb()
```

兩值傳入`test_memory_usage()`。report新增：
- `pre_load_rss_mb` — OS無模型時基線
- `post_load_rss_mb` — 模型載入後基線
- `model_footprint_mb` — 兩者之差，估算模型RAM佔用
- `transcription_delta_mb` — 轉錄過程峰值與post-load基線之差（原`delta_mb`）
- `note` — 說明psutil RSS含shared pages，macOS真實pressure見phys_footprint

exit criteria改為`transcription_delta_mb < 500 MB`，語義明確。

### 3. Test 2 RTF fallback

fallback路徑中，`duration < 60s`之文件標記為：

```json
{"pass": "skipped", "note": "Duration Xs < 60s — RTF not meaningful"}
```

不再以`pass: true/false`誤導。`MIN_MEANINGFUL_DURATION_S = 60.0`為具名常量。

### 4. Swift cleanup — defer

`test_activationPolicy_switchToAccessory_succeeds`：加`let originalPolicy = app.activationPolicy()` + `defer { app.setActivationPolicy(originalPolicy) }`。

`test_activationPolicy_roundTrip_remainsCoherent`：已有cleanup邏輯，改為defer模式，並刪除尾部手動呼叫（defer保證失敗時亦執行）。

---

## P2修復

### 5. requirements-dev.txt

加：
```
soundfile>=0.12.0
numpy>=1.24.0
```
附comment說明為phase0三腳本之必需依賴。

### 6. `_load_transcribe_module`加cache

兩腳本皆加module-level `_transcribe_mod_cache = None`，首次載入後緩存，後續呼叫直接返回。防止重複`exec_module`覆寫logging配置。docstring說明must use importlib path（不可標準import）。

### 7. Test 3 status語義

`status`改為`"observed"`（有數據）或`"skip"`（無數據），不用`"pass"`。

summary新增`"observed"`計數欄位，與`passed`分開。`note`欄說明reference為LibriSpeech/AISHELL ground truth，非model-vs-model。

### 8. 臨時文件洩漏

Test 6方法一（ffmpeg）、方法二（afconvert）、Test 7方法二（ffmpeg）：

```python
with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
    tmp_wav = tmp.name
try:
    # ... use tmp_wav ...
finally:
    if os.path.exists(tmp_wav):
        os.unlink(tmp_wav)
```

異常時臨時文件仍被清除。

---

## 未修（CR標記為無需修復）

- P2: `performActivity` XCTestExpectation多餘 — 同意CR分析，保留expectation以維持測試結構一致性，加comment說明此為synchronous call
- P2: `test_activationPolicy_switchToProhibited_doesNotCrash`無斷言 — 保留，已有comment說明意圖

---

## 附加修改（對應DA挑戰，詳見022）

- `prepare_test_audio.py`：加噪聲增強（SNR 15-20dB + room reverb），加磁盤空間guard（AISHELL < 20GB警告），manifest加tiling警告
- `phase0_spike.py`：加`--quick` flag（縮減集，~70%時間節省），加hardware info記錄，加estimated inference time提示
- `phase0_chunk_test.py`：SBER docstring說明一致性vs絕對準確度之區別

## out

P1/P2全部修復。代碼已寫入磁盤。CR可re-review上列文件。
