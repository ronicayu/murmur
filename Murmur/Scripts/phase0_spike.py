#!/usr/bin/env python3
"""
Phase 0 Validation Spike — Tests #1-7.

Directly imports transcribe.py functions; no Swift subprocess required.

Usage:
    python3 phase0_spike.py --model-path <path> [--test <id>] [--audio-dir <dir>] [--output report.json]

    --test: one of 1,2,3,4,5,6,7 or 'all' (default: all)
    --audio-dir: directory containing test WAV files (see prepare_test_audio.py)
    --output: JSON report path (default: phase0_report.json)

Exit criteria:
    Test 1  chunk stitching     < 5% sentence-break errors for best strategy
    Test 2  processing speed    RTF = processing_time / audio_duration, record all
    Test 3  single-speaker WER  record EN + ZH WER/CER
    Test 4  multi-speaker WER   WER < 80% → multi-speaker deferred
    Test 5  peak RAM            < model_baseline_mb + 500 MB
    Test 6  m4a decode          pass/fail
    Test 7  .ogg decode         pass/fail
"""

import argparse
import json
import os
import sys
import time
import glob
import logging
import subprocess
import tempfile
from pathlib import Path
from typing import Any

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("phase0")

# ---------------------------------------------------------------------------
# Lazy imports — allow partial runs without all deps installed
# ---------------------------------------------------------------------------

def _import_psutil():
    try:
        import psutil
        return psutil
    except ImportError:
        raise ImportError("psutil required: pip install psutil")


def _import_jiwer():
    try:
        import jiwer
        return jiwer
    except ImportError:
        raise ImportError("jiwer required: pip install jiwer")


def _import_numpy():
    import numpy as np
    return np


def _import_soundfile():
    try:
        import soundfile as sf
        return sf
    except ImportError:
        raise ImportError("soundfile required: pip install soundfile")


# ---------------------------------------------------------------------------
# transcribe.py import shim
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


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _list_wav_files(audio_dir: str, pattern: str = "*.wav") -> list[str]:
    files = sorted(glob.glob(os.path.join(audio_dir, "**", pattern), recursive=True))
    if not files:
        files = sorted(glob.glob(os.path.join(audio_dir, pattern)))
    return files


def _audio_duration_seconds(wav_path: str) -> float:
    sf = _import_soundfile()
    info = sf.info(wav_path)
    return info.duration


def _measure_rss_mb() -> float:
    psutil = _import_psutil()
    proc = psutil.Process(os.getpid())
    return proc.memory_info().rss / (1024 * 1024)


def _chunk_audio(audio: Any, sr: int, chunk_sec: float, overlap_sec: float) -> list[Any]:
    """Split a numpy array into overlapping chunks."""
    np = _import_numpy()
    chunk_samples = int(chunk_sec * sr)
    hop_samples = int((chunk_sec - overlap_sec) * sr)
    if hop_samples <= 0:
        hop_samples = chunk_samples
    chunks = []
    start = 0
    while start < len(audio):
        end = min(start + chunk_samples, len(audio))
        chunks.append(audio[start:end])
        if end == len(audio):
            break
        start += hop_samples
    return chunks


def _write_wav(audio: Any, sr: int, path: str):
    sf = _import_soundfile()
    sf.write(path, audio, sr)


def _normalise_text(text: str) -> str:
    """Lowercase and strip punctuation for robust text comparison."""
    import re
    return re.sub(r'[^\w\s]', '', text.lower())


def _sentence_break_error_rate(full_text: str, chunked_text: str) -> float:
    """
    Word-level overlap error rate at chunk boundaries.

    Definition: fraction of words in the full-file baseline that are absent
    from the chunked transcription output.  Measures content loss caused by
    chunk-boundary truncation (a word dropped at a boundary is genuinely
    missing from the hypothesis).

    Both inputs are normalised (lowercase, punctuation stripped) before
    comparison, so minor formatting differences are not counted as errors.

    Returns a ratio in [0, 1].  Lower is better.
    """
    norm_full = _normalise_text(full_text)
    norm_chunked = _normalise_text(chunked_text)

    full_words = norm_full.split()
    chunked_word_set = set(norm_chunked.split())

    if not full_words:
        return 0.0

    missing = sum(1 for w in full_words if w not in chunked_word_set)
    return missing / len(full_words)


# ---------------------------------------------------------------------------
# Test 1 — Chunk strategy
# ---------------------------------------------------------------------------

CHUNK_STRATEGIES = [
    {"name": "30s_5s_overlap",  "chunk_sec": 30,  "overlap_sec": 5},
    {"name": "60s_5s_overlap",  "chunk_sec": 60,  "overlap_sec": 5},
    {"name": "120s_5s_overlap", "chunk_sec": 120, "overlap_sec": 5},
]


def _vad_split(audio: Any, sr: int, frame_ms: int = 30, aggressiveness: int = 2) -> list[Any]:
    """
    Energy-based VAD split (fallback when webrtcvad unavailable).
    Returns list of audio segments at speech boundaries.
    """
    np = _import_numpy()
    frame_samples = int(sr * frame_ms / 1000)
    frames = [audio[i:i + frame_samples] for i in range(0, len(audio), frame_samples)]

    rms_values = [float(np.sqrt(np.mean(f.astype(np.float32) ** 2))) for f in frames if len(f) == frame_samples]
    if not rms_values:
        return [audio]

    threshold = float(np.percentile(rms_values, 20)) * 2.0

    speech_frames = [rms >= threshold for rms in rms_values]

    # Group contiguous speech frames into segments
    segments = []
    seg_start = None
    for idx, is_speech in enumerate(speech_frames):
        if is_speech and seg_start is None:
            seg_start = idx
        elif not is_speech and seg_start is not None:
            start_sample = seg_start * frame_samples
            end_sample = idx * frame_samples
            if (end_sample - start_sample) > sr * 0.5:  # min 0.5s segments
                segments.append(audio[start_sample:end_sample])
            seg_start = None

    if seg_start is not None:
        start_sample = seg_start * frame_samples
        segments.append(audio[start_sample:])

    return segments if segments else [audio]


def test_chunk_strategy(transcribe_mod, audio_dir: str, language: str = "en",
                        quick: bool = False) -> dict:
    """Test 1: compare chunk strategies vs full-file baseline.

    quick=True: use only 30min file + first 2 fixed-overlap strategies.
    Reduces wall-clock time ~70% for iteration.
    """
    log.info("=== Test 1: Chunk Strategy ===" + (" [QUICK]" if quick else ""))
    sf = _import_soundfile()

    # Use the longest available file (prefer 120s+ for meaningful chunking)
    wav_files = _list_wav_files(audio_dir, "*.wav")
    # Filter to files >= 60s; in quick mode prefer ~30min file
    min_dur = 60.0
    long_files = [(p, _audio_duration_seconds(p)) for p in wav_files if _audio_duration_seconds(p) >= min_dur]
    if not long_files:
        return {"status": "skip", "reason": "No WAV files >= 60s in audio_dir"}

    if quick:
        # Prefer file closest to 30 minutes to reduce inference time
        long_files.sort(key=lambda x: abs(x[1] - 1800))


    # Pick longest
    test_file, file_duration = max(long_files, key=lambda x: x[1])
    log.info(f"Using {test_file} ({file_duration:.0f}s) for chunk strategy test")

    audio, sr = sf.read(test_file)
    import numpy as np
    if len(np.array(audio).shape) > 1:
        audio = np.mean(audio, axis=1)

    # Full-file baseline transcription
    log.info("Computing full-file baseline transcription...")
    baseline_result = transcribe_mod.transcribe(test_file, language=language)
    baseline_text = baseline_result.get("text", "")
    log.info(f"Baseline: {len(baseline_text)} chars")

    results = []

    active_strategies = CHUNK_STRATEGIES[:2] if quick else CHUNK_STRATEGIES

    # Fixed-overlap strategies
    for strategy in active_strategies:
        name = strategy["name"]
        chunk_sec = strategy["chunk_sec"]
        overlap_sec = strategy["overlap_sec"]
        log.info(f"Testing strategy: {name}")

        chunks = _chunk_audio(audio, sr, chunk_sec, overlap_sec)
        log.info(f"  {len(chunks)} chunks")

        chunk_texts = []
        t0 = time.time()
        with tempfile.TemporaryDirectory() as tmpdir:
            for i, chunk in enumerate(chunks):
                chunk_path = os.path.join(tmpdir, f"chunk_{i:04d}.wav")
                _write_wav(chunk, sr, chunk_path)
                result = transcribe_mod.transcribe(chunk_path, language=language)
                chunk_texts.append(result.get("text", ""))

        elapsed = time.time() - t0
        combined_text = " ".join(chunk_texts).strip()
        sber = _sentence_break_error_rate(baseline_text, combined_text)

        results.append({
            "strategy": name,
            "chunk_sec": chunk_sec,
            "overlap_sec": overlap_sec,
            "num_chunks": len(chunks),
            "transcription_time_s": round(elapsed, 2),
            "sentence_break_error_rate": round(sber, 4),
            "pass": sber < 0.05,
        })
        log.info(f"  SBER={sber:.4f} {'PASS' if sber < 0.05 else 'FAIL'}")

    # VAD-based strategy
    log.info("Testing strategy: vad_energy")
    vad_segments = _vad_split(audio, sr)
    log.info(f"  VAD produced {len(vad_segments)} segments")
    vad_texts = []
    t0 = time.time()
    with tempfile.TemporaryDirectory() as tmpdir:
        for i, seg in enumerate(vad_segments):
            seg_path = os.path.join(tmpdir, f"vad_{i:04d}.wav")
            _write_wav(seg, sr, seg_path)
            result = transcribe_mod.transcribe(seg_path, language=language)
            vad_texts.append(result.get("text", ""))
    elapsed = time.time() - t0
    vad_text = " ".join(vad_texts).strip()
    vad_sber = _sentence_break_error_rate(baseline_text, vad_text)
    results.append({
        "strategy": "vad_energy",
        "num_segments": len(vad_segments),
        "transcription_time_s": round(elapsed, 2),
        "sentence_break_error_rate": round(vad_sber, 4),
        "pass": vad_sber < 0.05,
    })
    log.info(f"  SBER={vad_sber:.4f} {'PASS' if vad_sber < 0.05 else 'FAIL'}")

    best = min(results, key=lambda r: r["sentence_break_error_rate"])
    overall_pass = best["sentence_break_error_rate"] < 0.05

    return {
        "status": "pass" if overall_pass else "fail",
        "test_file": test_file,
        "file_duration_s": round(file_duration, 1),
        "baseline_chars": len(baseline_text),
        "strategies": results,
        "best_strategy": best["strategy"],
        "best_sber": best["sentence_break_error_rate"],
        "exit_criteria": "best_strategy SBER < 0.05",
    }


# ---------------------------------------------------------------------------
# Test 2 — Processing speed (RTF benchmark)
# ---------------------------------------------------------------------------

def test_processing_speed(transcribe_mod, audio_dir: str, language: str = "en",
                          quick: bool = False) -> dict:
    """Test 2: RTF for various audio durations."""
    log.info("=== Test 2: Processing Speed ===" + (" [QUICK]" if quick else ""))

    target_durations = [5, 30] if quick else [5, 15, 30, 60, 120]  # minutes
    results = []

    wav_files = _list_wav_files(audio_dir, "*.wav")
    duration_to_file: dict[int, str] = {}
    for wav in wav_files:
        d = _audio_duration_seconds(wav)
        for target in target_durations:
            target_sec = target * 60
            if abs(d - target_sec) < 30:  # within 30s of target
                duration_to_file[target] = wav

    MIN_MEANINGFUL_DURATION_S = 60.0  # RTF on short utterances is not meaningful

    if not duration_to_file:
        # Fall back: use whatever files exist, report their durations.
        # Files shorter than MIN_MEANINGFUL_DURATION_S are marked "skipped"
        # because RTF on short utterances reflects startup overhead, not
        # sustained throughput — a pass/fail verdict would be misleading.
        for wav in wav_files[:5]:
            d = _audio_duration_seconds(wav)
            if d < MIN_MEANINGFUL_DURATION_S:
                results.append({
                    "audio_duration_s": round(d, 1),
                    "processing_time_s": None,
                    "rtf": None,
                    "pass": "skipped",
                    "note": f"Duration {d:.1f}s < {MIN_MEANINGFUL_DURATION_S}s — RTF not meaningful",
                })
                continue
            t0 = time.time()
            transcribe_mod.transcribe(wav, language=language)
            elapsed = time.time() - t0
            rtf = elapsed / d if d > 0 else None
            results.append({
                "audio_duration_s": round(d, 1),
                "processing_time_s": round(elapsed, 2),
                "rtf": round(rtf, 4) if rtf else None,
                "pass": rtf is not None and rtf <= 2.0,
            })
    else:
        for target_min, wav_path in sorted(duration_to_file.items()):
            d = _audio_duration_seconds(wav_path)
            log.info(f"  Benchmarking {target_min}min file ({d:.0f}s)...")
            t0 = time.time()
            transcribe_mod.transcribe(wav_path, language=language)
            elapsed = time.time() - t0
            rtf = elapsed / d
            log.info(f"  RTF={rtf:.3f}  elapsed={elapsed:.1f}s")
            results.append({
                "target_minutes": target_min,
                "audio_duration_s": round(d, 1),
                "processing_time_s": round(elapsed, 2),
                "rtf": round(rtf, 4),
                "pass": rtf <= 2.0,
            })

    overall_pass = all(r.get("pass", False) for r in results) if results else False
    return {
        "status": "pass" if overall_pass else "fail",
        "results": results,
        "exit_criteria": "RTF <= 2.0 for all durations",
    }


# ---------------------------------------------------------------------------
# Test 3 — Single-speaker accuracy (WER / CER)
# ---------------------------------------------------------------------------

def _normalize_for_wer(text: str) -> str:
    """Normalize text for WER: lowercase, remove punctuation, collapse whitespace."""
    import re
    text = text.lower()
    text = re.sub(r"[^a-z0-9\s']", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _compute_wer(reference: str, hypothesis: str) -> float:
    jiwer = _import_jiwer()
    return jiwer.wer(_normalize_for_wer(reference), _normalize_for_wer(hypothesis))


def _compute_cer(reference: str, hypothesis: str) -> float:
    jiwer = _import_jiwer()
    return jiwer.cer(reference, hypothesis)


def _load_reference_transcripts(audio_dir: str) -> dict[str, str]:
    """
    Load .txt files alongside WAV files as reference transcripts.
    Convention: audio/foo.wav -> audio/foo.txt
    """
    refs = {}
    for wav in _list_wav_files(audio_dir, "*.wav"):
        txt_path = os.path.splitext(wav)[0] + ".txt"
        if os.path.exists(txt_path):
            with open(txt_path) as f:
                refs[wav] = f.read().strip()
    return refs


def test_single_speaker_accuracy(transcribe_mod, audio_dir: str) -> dict:
    """Test 3: WER/CER for single-speaker EN and ZH."""
    log.info("=== Test 3: Single-Speaker Accuracy ===")

    en_dir = os.path.join(audio_dir, "single_speaker", "en")
    zh_dir = os.path.join(audio_dir, "single_speaker", "zh")

    results_en = _accuracy_for_dir(transcribe_mod, en_dir, language="en", metric="wer", label="EN")
    results_zh = _accuracy_for_dir(transcribe_mod, zh_dir, language="zh", metric="cer", label="ZH")

    return {
        # "observed" signals this is a data-collection test with no hard pass threshold.
        # Using "pass" here would inflate the summary pass count and mislead PM.
        "status": "observed" if (results_en["has_data"] or results_zh["has_data"]) else "skip",
        "note": "Observational — WER/CER recorded for reference; no pass/fail threshold. "
                "Reference is ground-truth transcript (LibriSpeech/AISHELL), not model-vs-model.",
        "en": results_en,
        "zh": results_zh,
        "exit_criteria": "WER/CER recorded; no hard threshold for go/no-go",
    }


def _accuracy_for_dir(transcribe_mod, dir_path: str, language: str, metric: str, label: str) -> dict:
    if not os.path.isdir(dir_path):
        return {"has_data": False, "reason": f"Directory not found: {dir_path}"}

    refs = _load_reference_transcripts(dir_path)
    if not refs:
        return {"has_data": False, "reason": "No .txt reference transcripts found alongside WAV files"}

    scores = []
    for wav_path, reference in refs.items():
        log.info(f"  [{label}] transcribing {os.path.basename(wav_path)}")
        result = transcribe_mod.transcribe(wav_path, language=language)
        hypothesis = result.get("text", "")
        if metric == "wer":
            score = _compute_wer(reference, hypothesis)
        else:
            score = _compute_cer(reference, hypothesis)
        scores.append({"file": os.path.basename(wav_path), metric: round(score, 4)})
        log.info(f"    {metric.upper()}={score:.4f}")

    avg = sum(s[metric] for s in scores) / len(scores) if scores else None
    return {
        "has_data": True,
        "metric": metric,
        "scores": scores,
        "average": round(avg, 4) if avg is not None else None,
    }


# ---------------------------------------------------------------------------
# Test 4 — Multi-speaker accuracy
# ---------------------------------------------------------------------------

def test_multi_speaker_accuracy(transcribe_mod, audio_dir: str) -> dict:
    """Test 4: WER < 80% threshold. If fails, multi-speaker deferred."""
    log.info("=== Test 4: Multi-Speaker Accuracy ===")

    en_dir = os.path.join(audio_dir, "multi_speaker", "en")
    zh_dir = os.path.join(audio_dir, "multi_speaker", "zh")

    results_en = _accuracy_for_dir(transcribe_mod, en_dir, language="en", metric="wer", label="EN-multi")
    results_zh = _accuracy_for_dir(transcribe_mod, zh_dir, language="zh", metric="cer", label="ZH-multi")

    # Determine pass: WER < 0.8 for both languages that have data
    passes = []
    if results_en.get("has_data") and results_en.get("average") is not None:
        passes.append(results_en["average"] < 0.80)
    if results_zh.get("has_data") and results_zh.get("average") is not None:
        passes.append(results_zh["average"] < 0.80)

    if not passes:
        overall = "skip"
        recommendation = "No test data found"
    elif all(passes):
        overall = "pass"
        recommendation = "Multi-speaker supported"
    else:
        overall = "fail"
        recommendation = "WER >= 80% — defer multi-speaker to future release"

    return {
        "status": overall,
        "en": results_en,
        "zh": results_zh,
        "recommendation": recommendation,
        "exit_criteria": "WER < 0.80 for both EN and ZH; else multi-speaker deferred",
    }


# ---------------------------------------------------------------------------
# Test 5 — Memory usage
# ---------------------------------------------------------------------------

def test_memory_usage(
    transcribe_mod,
    audio_dir: str,
    language: str = "en",
    pre_load_rss_mb: float = 0.0,
    post_load_rss_mb: float = 0.0,
) -> dict:
    """Test 5: peak RSS during 120-min file processing.

    Args:
        pre_load_rss_mb:  RSS before load_model() — OS baseline without model.
        post_load_rss_mb: RSS after load_model() — model footprint included.
        The delta (post - pre) estimates the model's own RAM cost.
        Peak during transcription minus post_load gives the transcription increment.
    """
    log.info("=== Test 5: Memory Usage ===")
    psutil = _import_psutil()

    # Use the post-load baseline so delta_mb reflects transcription overhead only.
    # pre_load_rss_mb and post_load_rss_mb are recorded in the report for full picture.
    baseline_mb = post_load_rss_mb if post_load_rss_mb > 0 else _measure_rss_mb()
    log.info(f"Pre-load RSS: {pre_load_rss_mb:.1f} MB  Post-load RSS: {post_load_rss_mb:.1f} MB")

    # Find longest available file (prefer ~120min)
    wav_files = _list_wav_files(audio_dir, "*.wav")
    if not wav_files:
        return {"status": "skip", "reason": "No WAV files in audio_dir"}

    file_durations = [(p, _audio_duration_seconds(p)) for p in wav_files]
    test_file, file_duration = max(file_durations, key=lambda x: x[1])
    log.info(f"Memory test file: {test_file} ({file_duration:.0f}s)")

    # Monitor RSS in a background thread while transcribing
    import threading
    peak_rss = [baseline_mb]
    stop_event = threading.Event()

    def monitor():
        proc = psutil.Process(os.getpid())
        while not stop_event.is_set():
            try:
                rss = proc.memory_info().rss / (1024 * 1024)
                if rss > peak_rss[0]:
                    peak_rss[0] = rss
            except Exception:
                pass
            time.sleep(0.5)

    monitor_thread = threading.Thread(target=monitor, daemon=True)
    monitor_thread.start()

    t0 = time.time()
    transcribe_mod.transcribe(test_file, language=language)
    elapsed = time.time() - t0

    stop_event.set()
    monitor_thread.join(timeout=2)

    peak_mb = peak_rss[0]
    delta_mb = peak_mb - baseline_mb
    threshold_mb = 500.0
    passed = delta_mb < threshold_mb

    model_footprint_mb = post_load_rss_mb - pre_load_rss_mb if post_load_rss_mb > pre_load_rss_mb > 0 else None
    log.info(
        f"Pre-load={pre_load_rss_mb:.1f} MB  Post-load={post_load_rss_mb:.1f} MB  "
        f"Peak={peak_mb:.1f} MB  Transcription-delta={delta_mb:.1f} MB  "
        f"{'PASS' if passed else 'FAIL'}"
    )

    return {
        "status": "pass" if passed else "fail",
        "test_file": test_file,
        "file_duration_s": round(file_duration, 1),
        "processing_time_s": round(elapsed, 2),
        "pre_load_rss_mb": round(pre_load_rss_mb, 1),
        "post_load_rss_mb": round(post_load_rss_mb, 1),
        "model_footprint_mb": round(model_footprint_mb, 1) if model_footprint_mb is not None else None,
        "peak_rss_mb": round(peak_mb, 1),
        "transcription_delta_mb": round(delta_mb, 1),
        "threshold_mb": threshold_mb,
        "note": "delta = peak_during_transcription - post_load_baseline. "
                "psutil RSS includes shared pages; use phys_footprint (mach_task_info) "
                "for true private memory pressure on macOS.",
        "exit_criteria": "transcription_delta_mb < 500 MB",
    }


# ---------------------------------------------------------------------------
# Test 6 — m4a decode pipeline
# ---------------------------------------------------------------------------

def test_m4a_decode(audio_dir: str) -> dict:
    """Test 6: decode m4a to PCM at 16kHz mono."""
    log.info("=== Test 6: m4a Decode Pipeline ===")

    m4a_files = _list_wav_files(audio_dir, "*.m4a")
    if not m4a_files:
        # Try to create a test m4a from a WAV using ffmpeg
        wav_files = _list_wav_files(audio_dir, "*.wav")
        if not wav_files:
            return {"status": "skip", "reason": "No m4a or WAV files in audio_dir"}
        source_wav = wav_files[0]
        m4a_path = os.path.join(audio_dir, "_test_probe.m4a")
        ret = subprocess.run(
            ["ffmpeg", "-y", "-i", source_wav, "-c:a", "aac", "-b:a", "128k", m4a_path],
            capture_output=True,
        )
        if ret.returncode != 0:
            return {
                "status": "fail",
                "reason": "ffmpeg not available or encode failed",
                "stderr": ret.stderr.decode(errors="replace")[:500],
            }
        m4a_files = [m4a_path]

    test_file = m4a_files[0]
    log.info(f"Testing m4a decode: {test_file}")

    np = _import_numpy()

    # Method 1: ffmpeg to raw PCM (most reliable)
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_wav = tmp.name
        try:
            ret = subprocess.run(
                ["ffmpeg", "-y", "-i", test_file,
                 "-ar", "16000", "-ac", "1", "-f", "wav", tmp_wav],
                capture_output=True,
            )
            if ret.returncode != 0:
                raise RuntimeError(f"ffmpeg failed: {ret.stderr.decode(errors='replace')[:200]}")

            sf = _import_soundfile()
            audio, sr = sf.read(tmp_wav)
        finally:
            if os.path.exists(tmp_wav):
                os.unlink(tmp_wav)

        duration = len(audio) / sr
        log.info(f"m4a decode via ffmpeg: {duration:.2f}s at {sr}Hz  PASS")
        return {
            "status": "pass",
            "method": "ffmpeg",
            "test_file": test_file,
            "decoded_duration_s": round(duration, 2),
            "sample_rate": sr,
        }
    except Exception as e:
        log.warning(f"ffmpeg decode failed: {e}")

    # Method 2: AVFoundation via afconvert (macOS only)
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_wav = tmp.name
        try:
            ret = subprocess.run(
                ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", test_file, tmp_wav],
                capture_output=True,
            )
            if ret.returncode != 0:
                raise RuntimeError(f"afconvert failed: {ret.stderr.decode(errors='replace')[:200]}")

            sf = _import_soundfile()
            audio, sr = sf.read(tmp_wav)
        finally:
            if os.path.exists(tmp_wav):
                os.unlink(tmp_wav)

        duration = len(audio) / sr
        log.info(f"m4a decode via afconvert: {duration:.2f}s at {sr}Hz  PASS")
        return {
            "status": "pass",
            "method": "afconvert",
            "test_file": test_file,
            "decoded_duration_s": round(duration, 2),
            "sample_rate": sr,
        }
    except Exception as e:
        log.error(f"afconvert decode also failed: {e}")

    return {
        "status": "fail",
        "reason": "Both ffmpeg and afconvert failed to decode m4a",
        "test_file": test_file,
    }


# ---------------------------------------------------------------------------
# Test 7 — .ogg decode pipeline
# ---------------------------------------------------------------------------

def test_ogg_decode(audio_dir: str) -> dict:
    """Test 7: decode .ogg to PCM. Pass/fail."""
    log.info("=== Test 7: .ogg Decode Pipeline ===")

    ogg_files = _list_wav_files(audio_dir, "*.ogg")
    if not ogg_files:
        # Try to create a test ogg from a WAV using ffmpeg
        wav_files = _list_wav_files(audio_dir, "*.wav")
        if not wav_files:
            return {"status": "skip", "reason": "No .ogg or WAV files in audio_dir"}
        source_wav = wav_files[0]
        ogg_path = os.path.join(audio_dir, "_test_probe.ogg")
        ret = subprocess.run(
            ["ffmpeg", "-y", "-i", source_wav, "-c:a", "libvorbis", "-q:a", "4", ogg_path],
            capture_output=True,
        )
        if ret.returncode != 0:
            return {
                "status": "fail",
                "reason": "ffmpeg not available or ogg encode failed — cannot create test file",
                "stderr": ret.stderr.decode(errors="replace")[:500],
                "note": "AVFoundation does not natively support .ogg; ffmpeg required",
            }
        ogg_files = [ogg_path]

    test_file = ogg_files[0]
    log.info(f"Testing .ogg decode: {test_file}")

    # Method 1: soundfile (requires libvorbis/libsndfile ogg support)
    try:
        sf = _import_soundfile()
        audio, sr = sf.read(test_file)
        import numpy as np
        duration = len(np.array(audio)) / sr
        log.info(f".ogg decode via soundfile: {duration:.2f}s  PASS")
        return {
            "status": "pass",
            "method": "soundfile",
            "test_file": test_file,
            "decoded_duration_s": round(duration, 2),
            "sample_rate": sr,
            "note": "soundfile with libvorbis support available",
        }
    except Exception as e:
        log.warning(f"soundfile .ogg decode failed: {e}")

    # Method 2: ffmpeg
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_wav = tmp.name
        try:
            ret = subprocess.run(
                ["ffmpeg", "-y", "-i", test_file,
                 "-ar", "16000", "-ac", "1", "-f", "wav", tmp_wav],
                capture_output=True,
            )
            if ret.returncode != 0:
                raise RuntimeError(f"ffmpeg failed: {ret.stderr.decode(errors='replace')[:200]}")

            sf = _import_soundfile()
            audio, sr = sf.read(tmp_wav)
        finally:
            if os.path.exists(tmp_wav):
                os.unlink(tmp_wav)

        import numpy as np
        duration = len(np.array(audio)) / sr
        log.info(f".ogg decode via ffmpeg: {duration:.2f}s  PASS")
        return {
            "status": "pass",
            "method": "ffmpeg",
            "test_file": test_file,
            "decoded_duration_s": round(duration, 2),
            "sample_rate": sr,
            "note": "AVFoundation does not support .ogg natively; ffmpeg required as dependency",
        }
    except Exception as e:
        log.error(f"ffmpeg .ogg decode failed: {e}")

    return {
        "status": "fail",
        "reason": "Neither soundfile nor ffmpeg could decode .ogg",
        "test_file": test_file,
        "note": "AVFoundation does not support .ogg — consider dropping .ogg support",
    }


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

ALL_TESTS = {
    "1": ("chunk_strategy",      "test_chunk_strategy"),
    "2": ("processing_speed",    "test_processing_speed"),
    "3": ("single_speaker_wer",  "test_single_speaker_accuracy"),
    "4": ("multi_speaker_wer",   "test_multi_speaker_accuracy"),
    "5": ("memory_usage",        "test_memory_usage"),
    "6": ("m4a_decode",          "test_m4a_decode"),
    "7": ("ogg_decode",          "test_ogg_decode"),
}


def main():
    parser = argparse.ArgumentParser(description="Phase 0 Validation Spike — tests #1-7")
    parser.add_argument("--model-path", required=True, help="Path to model directory")
    parser.add_argument("--audio-dir", default="./test_audio", help="Directory with test WAV files")
    parser.add_argument("--test", default="all", help="Test id(s) to run: 1-7 or 'all' or comma-separated e.g. '1,2,5'")
    parser.add_argument("--language", default="en", choices=["en", "zh", "auto"], help="Transcription language for speed/chunk tests")
    parser.add_argument("--output", default="phase0_report.json", help="Output JSON report path")
    parser.add_argument("--quick", action="store_true",
                        help="Quick mode: Test 1 uses 30min file + 2 strategies only; "
                             "Test 2 uses 5/30min files only. Reduces wall-clock time ~70%%.")
    args = parser.parse_args()

    # Estimated inference time reminder (DA疑六)
    if not args.quick:
        log.info(
            "Estimated wall-clock for full run (RTF=0.5, M1 Pro): ~4-6 hours. "
            "Use --quick for a reduced set (~1-2 hours). "
            "Run prepare_test_audio.py --estimate-time for detailed breakdown."
        )

    if args.test == "all":
        test_ids = list(ALL_TESTS.keys())
    else:
        test_ids = [t.strip() for t in args.test.split(",")]

    # Load model once — sample RSS before and after for Test 5 memory baseline.
    log.info(f"Loading model from {args.model_path}")
    transcribe_mod = _load_transcribe_module()
    pre_load_rss_mb = _measure_rss_mb()
    load_result = transcribe_mod.load_model(args.model_path)
    post_load_rss_mb = _measure_rss_mb()
    if "error" in load_result:
        log.error(f"Model load failed: {load_result['error']}")
        sys.exit(1)
    log.info(f"Model loaded. RSS: {pre_load_rss_mb:.1f} MB -> {post_load_rss_mb:.1f} MB "
             f"(model footprint ~{post_load_rss_mb - pre_load_rss_mb:.1f} MB)")

    # Record hardware info — exit criteria are M1 Pro-specific; results on other
    # Apple Silicon may differ. M1 (base) RTF may be 2-3x higher than M1 Pro.
    hw_info: dict[str, Any] = {"platform": sys.platform}
    try:
        chip = subprocess.run(
            ["sysctl", "-n", "machdep.cpu.brand_string"],
            capture_output=True, text=True, timeout=5
        ).stdout.strip()
        hw_info["cpu"] = chip
    except Exception:
        pass
    try:
        mem_bytes = int(subprocess.run(
            ["sysctl", "-n", "hw.memsize"],
            capture_output=True, text=True, timeout=5
        ).stdout.strip())
        hw_info["ram_gb"] = round(mem_bytes / 1024 ** 3, 1)
    except Exception:
        pass

    report: dict[str, Any] = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "model_path": args.model_path,
        "audio_dir": args.audio_dir,
        "hardware": hw_info,
        "quick_mode": args.quick,
        "tests": {},
    }

    for test_id in test_ids:
        if test_id not in ALL_TESTS:
            log.warning(f"Unknown test id: {test_id}, skipping")
            continue

        test_name, func_name = ALL_TESTS[test_id]
        func = globals()[func_name]
        log.info(f"\n--- Running test {test_id}: {test_name} ---")

        try:
            if test_id in ("1", "2"):
                result = func(transcribe_mod, args.audio_dir, args.language,
                              quick=args.quick)
            elif test_id in ("3", "4"):
                result = func(transcribe_mod, args.audio_dir)
            elif test_id == "5":
                result = func(
                    transcribe_mod, args.audio_dir, args.language,
                    pre_load_rss_mb=pre_load_rss_mb,
                    post_load_rss_mb=post_load_rss_mb,
                )
            elif test_id in ("6", "7"):
                result = func(args.audio_dir)
            else:
                result = {}
        except Exception as e:
            log.exception(f"Test {test_id} raised exception")
            result = {"status": "error", "error": str(e)}

        report["tests"][test_name] = result

    # Summary
    # "observed" tests (Test 3) have no hard threshold — excluded from pass/fail counts.
    statuses = [v.get("status") for v in report["tests"].values()]
    passed = sum(1 for s in statuses if s == "pass")
    failed = sum(1 for s in statuses if s == "fail")
    observed = sum(1 for s in statuses if s == "observed")
    skipped = sum(1 for s in statuses if s in ("skip", "error"))
    report["summary"] = {
        "passed": passed,
        "failed": failed,
        "observed": observed,
        "skipped": skipped,
        "total": len(statuses),
        "overall": "pass" if failed == 0 and passed > 0 else ("fail" if failed > 0 else "skip"),
        "note": "'observed' tests record data only; not counted in pass/fail.",
    }

    output_path = args.output
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    log.info(f"\n=== Summary: {passed} pass, {failed} fail, {skipped} skip ===")
    log.info(f"Report written to {output_path}")

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
