# SenseVoice-Small Spike — Results

> **Historical record (added 2026-10-10).** Kept for the measurements. The
> harness script and the `SenseVoiceTranscriptionService` prototype this note
> refers to were not brought into `main`, and the engines it compares against
> (Cohere, FireRed) have since been removed: Murmur now runs Qwen3-ASR only.
> The fixtures and file paths mentioned below no longer exist.

**Date:** 2026-06-28
**Branch:** `spike/sensevoice`
**Question:** Is FunASR/SenseVoice a better engine than Cohere — specifically for the
streaming pass (Cohere is "not so fast"; European langs dropped from scope) and for
zh-en code-switching?

## Setup
- Model: `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17`, **int8 = 239 MB**
  (vs Cohere ~1.5 GB, FireRed ~1.24 GB).
- Run via sherpa-onnx Python 1.13.3 (same C library as the vendored xcframework),
  `num_threads=4`, `provider=cpu`, `use_itn=True`, `language=auto` (per-utterance LID).
- Harness: `Murmur/Scripts/sensevoice_spike.py`. Swift service written:
  `Murmur/Services/SenseVoiceTranscriptionService.swift` (mirrors FireRed; not wired in).
- Scored against existing fixtures: short zh ground truth + FireRed ref for the
  14.7 s zh-en code-switch clip (`firered_refs.json`).

## Numbers
Model load: **943 ms**. Median **RTF 0.017 (~58× realtime)**.

| Clip | Audio | Latency | RTF | LID | CER |
|---|---|---|---|---|---|
| `test_chinese.wav` (short zh) | 3.7 s | 60 ms | 0.016 | zh ✓ | **0.0%** vs truth |
| `test_chinese_en.wav` (zh-en mix) | 14.7 s | 267 ms | 0.018 | zh | **23.1%** vs FireRed |

ja/ko/en/yue sanity (model's own test_wavs) — all LID-correct, coherent output:
- en: "The tribal chieftain called for the boy and presented him with 50 pieces of code." (1 word off: gold→code)
- ja: "うちの中学は弁当制で持っていけない場合は50円の学校販売のパンを買う。" ✓
- ko: "조금만 생각을 하면서 살면 훨씬 편할 거야." ✓
- yue / zh: ✓

## Findings
1. **Speed + footprint = decisive win.** ~58× realtime, 239 MB. The growing-buffer +
   stable-prefix streaming strategy is trivially affordable (re-transcribe a 5 s buffer
   ≈ 90 ms). This validates the streaming-fix plan from a perf standpoint.
2. **Simple zh / en / ja / ko = excellent.** 0% CER on plain Chinese; clean, LID-correct
   ja/ko/en. As a *mono-lingual* streaming engine for zh/en/ja/ko it's strong.
3. **zh-en code-switching = the dealbreaker (23% CER).** Chinese is perfect; the
   **English technical terms embedded in Chinese are mangled**, which is the worst place
   to fail (they carry the meaning):
   - "deep learning" → "de learning"
   - "data analytics" → "datata analyticslytic"
   - "data science" → "datata scienceence"
   - "scientist" → "sent"
   - "again" → "a"
   Root cause is architectural: SenseVoice assigns **one** language per utterance
   (LID = zh here) — embedded English degrades. FireRed (the zh-en specialist already in
   the app) gets these terms right.

## Verdict
- **Mono-lingual zh/en/ja/ko dictation:** SenseVoice is a great streaming engine — fast,
  tiny, accurate. Worth phase 2 (streaming loop).
- **Heavy zh-en tech code-switching:** SenseVoice on the live pass would inject garbled
  English terms. Not acceptable alone for that use case. Would need a FireRed/Cohere
  finalize pass to repair on stop, or keep the current model.

## License
Model LICENSE → FunASR license (code MIT; SenseVoice model under ModelScope model
agreement). **Verify commercial terms before bundling.**

## Next (phase 2, if go)
1. Build the Swift test path (`SenseVoiceTranscriptionService` + xcframework) to confirm
   these numbers on the shipping path (should match — same C lib).
2. Prototype growing-buffer + stable-prefix streaming with SenseVoice as live engine.
3. Decide finalize-pass engine for code-switch repair (FireRed for zh / Cohere otherwise).
