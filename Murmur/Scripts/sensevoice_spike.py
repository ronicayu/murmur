#!/usr/bin/env python3
"""SPIKE: benchmark SenseVoice-Small int8 (sherpa-onnx) on Murmur's fixtures.

Answers: is SenseVoice good enough on zh + zh-en code-switching, and how fast,
to justify replacing Cohere on the *streaming* pass? Scores against the FireRed
reference (the zh-en champion already in firered_refs.json) + the short-clip ref.

Run:
  pip install sherpa-onnx soundfile jiwer numpy
  python Murmur/Scripts/sensevoice_spike.py \
      --model <dir-with model.int8.onnx + tokens.txt> \
      --fixtures Murmur/test_fixtures \
      --extra-wavs <sensevoice test_wavs dir>   # optional ja/ko/en/yue sanity
"""
import argparse, json, time, re, statistics
from pathlib import Path

import numpy as np
import soundfile as sf
import sherpa_onnx
from jiwer import cer


def load_16k_mono(path: Path):
    samples, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if samples.ndim > 1:                      # downmix to mono
        samples = samples.mean(axis=1)
    assert sr == 16000, f"{path.name}: expected 16 kHz, got {sr}"
    return np.ascontiguousarray(samples), sr


def normalize(s: str) -> str:
    """CER-friendly normalization: drop spaces + punctuation, lowercase.
    Chinese ASR refs differ cosmetically on spacing/punct; we score content."""
    s = s.lower()
    s = re.sub(r"[\s]", "", s)
    s = re.sub(r"[,.，。!！?？\"'""''、:：;；]", "", s)
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="dir with model.int8.onnx + tokens.txt")
    ap.add_argument("--fixtures", required=True, help="Murmur/test_fixtures dir")
    ap.add_argument("--extra-wavs", default=None, help="optional dir of labelled-by-name wavs")
    ap.add_argument("--threads", type=int, default=4)
    args = ap.parse_args()

    model_dir = Path(args.model)
    fix = Path(args.fixtures)

    t0 = time.perf_counter()
    rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=str(model_dir / "model.int8.onnx"),
        tokens=str(model_dir / "tokens.txt"),
        num_threads=args.threads,
        use_itn=True,
        language="auto",       # enable per-utterance LID
        debug=False,
    )
    load_ms = (time.perf_counter() - t0) * 1000
    print(f"# SenseVoice-Small int8 loaded in {load_ms:.0f} ms (threads={args.threads})\n")

    firered = json.loads((fix / "firered_refs.json").read_text())
    cohere_refs = json.loads((fix / "transcription_refs.json").read_text())

    # clip -> (path, reference-text-or-None, reference-source-label)
    jobs = [
        ("test_chinese.wav",
         "你好呀,现在可以了吗?", "ground truth (short zh)"),
        ("test_chinese_en.wav",
         firered["test_chinese_en_wav_zh"]["text"], "FireRed ref (zh-en mix)"),
    ]

    def run(path: Path):
        samples, sr = load_16k_mono(path)
        dur_s = len(samples) / sr
        t = time.perf_counter()
        s = rec.create_stream()
        s.accept_waveform(sr, samples)
        rec.decode_stream(s)
        ms = (time.perf_counter() - t) * 1000
        res = s.result
        lang = getattr(res, "lang", "") or ""
        return res.text, lang, ms, dur_s

    rows = []
    print("=" * 100)
    for name, ref, ref_src in jobs:
        p = fix / name
        if not p.exists():
            print(f"[skip] {name} missing"); continue
        text, lang, ms, dur_s = run(p)
        rtf = (ms / 1000) / dur_s if dur_s else 0
        score = cer(normalize(ref), normalize(text)) if ref else None
        rows.append((name, dur_s, ms, rtf, lang, score))
        print(f"\n## {name}  ({dur_s:.1f}s audio, lang={lang or '?'})")
        print(f"   latency : {ms:.0f} ms   RTF : {rtf:.3f}  ({1/rtf:.0f}x realtime)")
        if ref is not None:
            print(f"   CER vs {ref_src} : {score*100:.1f}%")
            print(f"   REF : {ref}")
        print(f"   OUT : {text}")

    if args.extra_wavs:
        print("\n" + "=" * 100)
        print("## ja / ko / en / yue sanity (no ref — eyeball)\n")
        for p in sorted(Path(args.extra_wavs).glob("*.wav")):
            text, lang, ms, dur_s = run(p)
            print(f"  {p.name:10s} lang={lang or '?':4s} {ms:5.0f}ms  {text}")

    if rows:
        print("\n" + "=" * 100)
        print("SUMMARY")
        lat = [r[2] for r in rows]
        rtfs = [r[3] for r in rows]
        print(f"  median latency : {statistics.median(lat):.0f} ms")
        print(f"  median RTF     : {statistics.median(rtfs):.3f}  (~{1/statistics.median(rtfs):.0f}x realtime)")
        scored = [r[5] for r in rows if r[5] is not None]
        if scored:
            print(f"  mean CER       : {statistics.mean(scored)*100:.1f}%")


if __name__ == "__main__":
    main()
