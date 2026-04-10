#!/usr/bin/env python3
"""
Phase 0 — Chunk Strategy Detailed Test (Test #1 deep-dive).

Compares fixed-overlap chunking vs energy-based VAD splitting.
Measures sentence-break errors and transcription quality
against a full-file baseline.

Usage:
    python3 phase0_chunk_test.py --model-path <path> --audio <file.wav> [--language en] [--output chunk_report.json]

Output: JSON report with per-strategy metrics.

Dependencies: soundfile, numpy (required); webrtcvad (optional, for proper VAD)
"""

import argparse
import json
import os
import sys
import time
import tempfile
import logging
from pathlib import Path
from typing import Any

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("chunk_test")


# ---------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------

_transcribe_mod_cache = None


def _load_transcribe_module():
    """Import transcribe.py from the Scripts directory.

    Cached: repeated calls return the same module object, preventing
    re-execution of transcribe.py top-level code (logging config, torch import).
    Must use importlib path — do NOT import via sys.path; the module uses
    global state that would not be shared with a standard import.
    """
    global _transcribe_mod_cache
    if _transcribe_mod_cache is not None:
        return _transcribe_mod_cache

    scripts_dir = Path(__file__).parent
    transcribe_path = scripts_dir / "transcribe.py"
    if not transcribe_path.exists():
        raise FileNotFoundError(f"transcribe.py not found at {transcribe_path}")
    import importlib.util
    spec = importlib.util.spec_from_file_location("transcribe", str(transcribe_path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    _transcribe_mod_cache = mod
    return mod


def _import_soundfile():
    try:
        import soundfile as sf
        return sf
    except ImportError:
        raise ImportError("soundfile required: pip install soundfile")


def _import_numpy():
    import numpy as np
    return np


# ---------------------------------------------------------------------------
# Audio helpers
# ---------------------------------------------------------------------------

def load_audio_mono_16k(path: str):
    """Load any WAV/FLAC to mono float32 at 16kHz."""
    sf = _import_soundfile()
    np = _import_numpy()
    audio, sr = sf.read(path, dtype="float32")
    if len(audio.shape) > 1:
        audio = np.mean(audio, axis=1)
    if sr != 16000:
        try:
            import librosa
            audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)
        except ImportError:
            raise ImportError("librosa required for resampling: pip install librosa")
        sr = 16000
    return audio, sr


def write_wav(audio, sr: int, path: str):
    sf = _import_soundfile()
    sf.write(path, audio, sr)


# ---------------------------------------------------------------------------
# Chunking strategies
# ---------------------------------------------------------------------------

FIXED_OVERLAP_STRATEGIES = [
    {"name": "30s_5s_overlap",  "chunk_sec": 30,  "overlap_sec": 5},
    {"name": "60s_5s_overlap",  "chunk_sec": 60,  "overlap_sec": 5},
    {"name": "120s_5s_overlap", "chunk_sec": 120, "overlap_sec": 5},
]


def fixed_overlap_chunks(audio, sr: int, chunk_sec: float, overlap_sec: float) -> list:
    """Produce a list of overlapping audio chunks."""
    chunk_samples = int(chunk_sec * sr)
    hop_samples = int((chunk_sec - overlap_sec) * sr)
    if hop_samples <= 0:
        hop_samples = chunk_samples
    chunks = []
    start = 0
    while start < len(audio):
        end = min(start + chunk_samples, len(audio))
        chunks.append((start / sr, end / sr, audio[start:end]))
        if end == len(audio):
            break
        start += hop_samples
    return chunks


def energy_vad_chunks(audio, sr: int, frame_ms: int = 30, min_segment_sec: float = 0.5,
                       energy_percentile: float = 20, energy_multiplier: float = 2.0) -> list:
    """
    Energy-based VAD: label frames as speech/silence, group speech into segments.
    Returns list of (start_sec, end_sec, audio_array).
    """
    np = _import_numpy()
    frame_samples = int(sr * frame_ms / 1000)
    frames = [audio[i:i + frame_samples] for i in range(0, len(audio), frame_samples)
              if i + frame_samples <= len(audio)]

    rms_values = [float(np.sqrt(np.mean(f ** 2))) for f in frames]
    if not rms_values:
        return [(0.0, len(audio) / sr, audio)]

    threshold = float(np.percentile(rms_values, energy_percentile)) * energy_multiplier
    speech_flags = [rms >= threshold for rms in rms_values]

    segments = []
    seg_start = None
    for idx, is_speech in enumerate(speech_flags):
        if is_speech and seg_start is None:
            seg_start = idx
        elif not is_speech and seg_start is not None:
            start_sample = seg_start * frame_samples
            end_sample = idx * frame_samples
            duration = (end_sample - start_sample) / sr
            if duration >= min_segment_sec:
                t_start = start_sample / sr
                t_end = end_sample / sr
                segments.append((t_start, t_end, audio[start_sample:end_sample]))
            seg_start = None

    if seg_start is not None:
        start_sample = seg_start * frame_samples
        t_start = start_sample / sr
        t_end = len(audio) / sr
        segments.append((t_start, t_end, audio[start_sample:]))

    return segments if segments else [(0.0, len(audio) / sr, audio)]


def webrtcvad_chunks(audio, sr: int, aggressiveness: int = 2,
                      frame_ms: int = 30, min_segment_sec: float = 0.3) -> list:
    """
    webrtcvad-based VAD. Falls back to energy VAD if webrtcvad unavailable.
    webrtcvad requires 16kHz, 16-bit PCM.
    """
    try:
        import webrtcvad
    except ImportError:
        log.warning("webrtcvad not installed — falling back to energy VAD")
        return energy_vad_chunks(audio, sr)

    np = _import_numpy()

    vad = webrtcvad.Vad(aggressiveness)
    frame_samples = int(sr * frame_ms / 1000)

    # Convert to 16-bit PCM bytes
    audio_int16 = (audio * 32767).astype(np.int16)

    segments = []
    seg_start = None

    for i in range(0, len(audio_int16) - frame_samples, frame_samples):
        frame_bytes = audio_int16[i:i + frame_samples].tobytes()
        try:
            is_speech = vad.is_speech(frame_bytes, sample_rate=sr)
        except Exception:
            is_speech = False

        if is_speech and seg_start is None:
            seg_start = i
        elif not is_speech and seg_start is not None:
            duration = (i - seg_start) / sr
            if duration >= min_segment_sec:
                t_start = seg_start / sr
                t_end = i / sr
                segments.append((t_start, t_end, audio[seg_start:i]))
            seg_start = None

    if seg_start is not None:
        t_start = seg_start / sr
        t_end = len(audio) / sr
        segments.append((t_start, t_end, audio[seg_start:]))

    return segments if segments else energy_vad_chunks(audio, sr)


# ---------------------------------------------------------------------------
# Quality metrics
# ---------------------------------------------------------------------------

def _normalise_text(text: str) -> str:
    """Lowercase and strip punctuation for robust text comparison."""
    import re
    return re.sub(r'[^\w\s]', '', text.lower())


def sentence_break_error_rate(baseline_text: str, hypothesis_text: str) -> float:
    """
    Word-level overlap error rate at chunk boundaries.

    Definition: fraction of words in the full-file baseline that are absent
    from the chunked transcription output.  Measures content loss caused by
    chunk-boundary truncation (a word dropped at a boundary is genuinely
    missing from the hypothesis).

    Both inputs are normalised (lowercase, punctuation stripped) before
    comparison, so minor formatting differences are not counted as errors.

    Returns a ratio in [0, 1].  Lower is better.

    Note: this metric measures chunked-vs-full-file consistency, NOT
    absolute accuracy against a ground-truth transcript.  A low score means
    the chunk strategy preserves most words relative to full-file baseline;
    it does not imply the baseline itself is correct.
    """
    norm_baseline = _normalise_text(baseline_text)
    norm_hypothesis = _normalise_text(hypothesis_text)

    baseline_words = norm_baseline.split()
    hypothesis_word_set = set(norm_hypothesis.split())

    if not baseline_words:
        return 0.0

    missing = sum(1 for w in baseline_words if w not in hypothesis_word_set)
    return missing / len(baseline_words)


def word_overlap_score(baseline_text: str, hypothesis_text: str) -> float:
    """Macro word overlap (1 - WER approximation without alignment)."""
    baseline_words = set(baseline_text.lower().split())
    hyp_words = set(hypothesis_text.lower().split())
    if not baseline_words:
        return 1.0
    intersection = baseline_words & hyp_words
    return len(intersection) / len(baseline_words)


# ---------------------------------------------------------------------------
# Run one strategy
# ---------------------------------------------------------------------------

def run_strategy(
    transcribe_mod,
    strategy_name: str,
    chunks: list,
    language: str,
    tmpdir: str,
) -> dict[str, Any]:
    """Transcribe all chunks; return combined text and timing."""
    texts = []
    total_time = 0.0
    chunk_details = []

    for i, item in enumerate(chunks):
        t_start, t_end, audio_chunk = item
        chunk_path = os.path.join(tmpdir, f"{strategy_name}_{i:04d}.wav")
        write_wav(audio_chunk, 16000, chunk_path)

        t0 = time.time()
        result = transcribe_mod.transcribe(chunk_path, language=language)
        elapsed = time.time() - t0

        chunk_text = result.get("text", "")
        texts.append(chunk_text)
        total_time += elapsed
        chunk_details.append({
            "chunk_index": i,
            "start_s": round(t_start, 2),
            "end_s": round(t_end, 2),
            "duration_s": round(t_end - t_start, 2),
            "transcription_time_s": round(elapsed, 3),
            "text_chars": len(chunk_text),
        })

    combined = " ".join(texts).strip()
    return {
        "combined_text": combined,
        "total_transcription_time_s": round(total_time, 2),
        "num_chunks": len(chunks),
        "chunk_details": chunk_details,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Phase 0 — Chunk Strategy Deep Test")
    parser.add_argument("--model-path", required=True, help="Path to model directory")
    parser.add_argument("--audio", required=True, help="Test audio file (WAV, min 60s recommended)")
    parser.add_argument("--language", default="en", choices=["en", "zh", "auto"])
    parser.add_argument("--output", default="chunk_report.json", help="Output JSON path")
    parser.add_argument("--vad-aggressiveness", type=int, default=2, choices=[0, 1, 2, 3],
                        help="webrtcvad aggressiveness (0=least, 3=most)")
    args = parser.parse_args()

    if not os.path.exists(args.audio):
        log.error(f"Audio file not found: {args.audio}")
        sys.exit(1)

    # Load model
    log.info(f"Loading model from {args.model_path}")
    transcribe_mod = _load_transcribe_module()
    load_result = transcribe_mod.load_model(args.model_path)
    if "error" in load_result:
        log.error(f"Model load failed: {load_result['error']}")
        sys.exit(1)
    log.info("Model loaded.")

    # Load audio
    log.info(f"Loading audio: {args.audio}")
    audio, sr = load_audio_mono_16k(args.audio)
    file_duration = len(audio) / sr
    log.info(f"Audio duration: {file_duration:.1f}s ({file_duration/60:.1f} min)")

    if file_duration < 30:
        log.warning(f"Audio is only {file_duration:.1f}s — chunking tests are most meaningful on >60s files")

    # Full-file baseline
    log.info("Computing full-file baseline...")
    t0 = time.time()
    baseline_result = transcribe_mod.transcribe(args.audio, language=args.language)
    baseline_time = time.time() - t0
    baseline_text = baseline_result.get("text", "")
    baseline_rtf = baseline_time / file_duration if file_duration > 0 else None
    log.info(f"Baseline: {len(baseline_text)} chars, {baseline_time:.1f}s (RTF={baseline_rtf:.3f})")

    report: dict[str, Any] = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "audio_file": args.audio,
        "audio_duration_s": round(file_duration, 1),
        "language": args.language,
        "baseline": {
            "text_chars": len(baseline_text),
            "processing_time_s": round(baseline_time, 2),
            "rtf": round(baseline_rtf, 4) if baseline_rtf else None,
        },
        "strategies": {},
    }

    with tempfile.TemporaryDirectory() as tmpdir:
        # Fixed overlap strategies
        for strategy in FIXED_OVERLAP_STRATEGIES:
            name = strategy["name"]
            chunk_sec = strategy["chunk_sec"]
            overlap_sec = strategy["overlap_sec"]

            if chunk_sec >= file_duration:
                log.info(f"Skipping {name} — chunk_sec ({chunk_sec}s) >= file duration ({file_duration:.0f}s)")
                report["strategies"][name] = {
                    "status": "skip",
                    "reason": f"chunk_sec={chunk_sec}s >= file_duration={file_duration:.0f}s",
                }
                continue

            log.info(f"Strategy: {name}")
            chunks = fixed_overlap_chunks(audio, sr, chunk_sec, overlap_sec)
            log.info(f"  {len(chunks)} chunks")

            run_result = run_strategy(transcribe_mod, name, chunks, args.language, tmpdir)
            sber = sentence_break_error_rate(baseline_text, run_result["combined_text"])
            overlap_score = word_overlap_score(baseline_text, run_result["combined_text"])
            rtf = run_result["total_transcription_time_s"] / file_duration if file_duration > 0 else None

            report["strategies"][name] = {
                "type": "fixed_overlap",
                "chunk_sec": chunk_sec,
                "overlap_sec": overlap_sec,
                "num_chunks": run_result["num_chunks"],
                "processing_time_s": run_result["total_transcription_time_s"],
                "rtf": round(rtf, 4) if rtf else None,
                "sentence_break_error_rate": round(sber, 4),
                "word_overlap_score": round(overlap_score, 4),
                "pass": sber < 0.05,
                "chunk_details": run_result["chunk_details"],
            }
            log.info(f"  SBER={sber:.4f}  overlap={overlap_score:.4f}  RTF={rtf:.3f}  {'PASS' if sber < 0.05 else 'FAIL'}")

        # VAD strategies
        for vad_name, vad_fn, vad_kwargs in [
            ("vad_energy", energy_vad_chunks, {}),
            ("vad_webrtc", webrtcvad_chunks, {"aggressiveness": args.vad_aggressiveness}),
        ]:
            log.info(f"Strategy: {vad_name}")
            chunks = vad_fn(audio, sr, **vad_kwargs)
            log.info(f"  {len(chunks)} segments")

            run_result = run_strategy(transcribe_mod, vad_name, chunks, args.language, tmpdir)
            sber = sentence_break_error_rate(baseline_text, run_result["combined_text"])
            overlap_score = word_overlap_score(baseline_text, run_result["combined_text"])
            rtf = run_result["total_transcription_time_s"] / file_duration if file_duration > 0 else None

            report["strategies"][vad_name] = {
                "type": "vad",
                "vad_method": vad_name,
                "num_segments": run_result["num_chunks"],
                "processing_time_s": run_result["total_transcription_time_s"],
                "rtf": round(rtf, 4) if rtf else None,
                "sentence_break_error_rate": round(sber, 4),
                "word_overlap_score": round(overlap_score, 4),
                "pass": sber < 0.05,
                "chunk_details": run_result["chunk_details"],
            }
            log.info(f"  SBER={sber:.4f}  overlap={overlap_score:.4f}  RTF={rtf:.3f}  {'PASS' if sber < 0.05 else 'FAIL'}")

    # Find best strategy
    valid = {k: v for k, v in report["strategies"].items() if v.get("status") != "skip"}
    if valid:
        best_key = min(valid.keys(), key=lambda k: valid[k].get("sentence_break_error_rate", 1.0))
        report["recommendation"] = {
            "best_strategy": best_key,
            "sber": valid[best_key].get("sentence_break_error_rate"),
            "pass": valid[best_key].get("pass", False),
        }

    output_path = args.output
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    log.info(f"Report written to {output_path}")
    best_sber = report.get("recommendation", {}).get("sber", 1.0)
    sys.exit(0 if best_sber < 0.05 else 1)


if __name__ == "__main__":
    main()
