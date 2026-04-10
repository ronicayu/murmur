#!/usr/bin/env python3
"""
V3 Phase 0 Validation Spike — Tests #1, #2, #3, #5.

Validates the core engineering assumptions behind V3 streaming voice input.
Directly imports transcribe.py inference functions; no Swift subprocess required.

Usage:
    python3 v3_phase0_spike.py --model-path <path> [--test 1|2|3|5|all] \
        [--audio-dir <dir>] [--output report.json]

Tests:
    1 — Chunk size boundary error rate (2s / 3s / 5s chunks, edit distance vs full-file)
    2 — First-chunk latency (audio load → processor → encoder → decoder → text), 10 runs each
    3 — CPU utilization during 30s streaming session (10 × 3s chunks continuous)
    5 — Streaming vs full-pass difference (10 clips, edit distance of concatenated chunks)

Exit criteria (from spec rev 3):
    #1  At least one chunk size: first chunk < 5s AND boundary error rate < 10%
    #2  Median first-chunk latency < 5s on M1 16GB. Median > 8s → V3 kill signal
    #3  Sustained CPU < 80%. Sustained > 90% for any window → throttle/cancel warning
    #5  Average edit distance < 20%. > 40% → V3 kill signal
"""

import argparse
import json
import os
import sys
import time
import logging
import statistics
import tempfile
from pathlib import Path
from typing import Any

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("v3_spike")

# ---------------------------------------------------------------------------
# Lazy imports
# ---------------------------------------------------------------------------

def _import_psutil():
    try:
        import psutil
        return psutil
    except ImportError:
        raise ImportError("psutil required: pip install psutil")


def _import_numpy():
    import numpy as np
    return np


def _import_soundfile():
    try:
        import soundfile as sf
        return sf
    except ImportError:
        raise ImportError("soundfile required: pip install soundfile")


def _import_editdistance():
    try:
        import editdistance
        return editdistance
    except ImportError:
        raise ImportError("editdistance required: pip install editdistance")


# ---------------------------------------------------------------------------
# transcribe.py import shim — mirrors phase0_spike.py pattern
# ---------------------------------------------------------------------------

_transcribe_mod_cache = None


def _load_transcribe_module(script_path: str):
    """Import transcribe.py as a module, bypassing __name__=='__main__' guards."""
    global _transcribe_mod_cache
    if _transcribe_mod_cache is not None:
        return _transcribe_mod_cache

    import importlib.util
    spec = importlib.util.spec_from_file_location("transcribe_mod", script_path)
    mod = importlib.util.module_from_spec(spec)
    # Prevent the module from running its stdin loop on import
    mod.__name__ = "transcribe_mod"
    spec.loader.exec_module(mod)
    _transcribe_mod_cache = mod
    return mod


def _resolve_transcribe_path(explicit: str | None) -> str:
    candidates = []
    if explicit:
        candidates.append(explicit)
    # Same directory as this script
    candidates.append(str(Path(__file__).parent / "transcribe.py"))
    for c in candidates:
        if os.path.isfile(c):
            return c
    raise FileNotFoundError(
        "transcribe.py not found. Pass --transcribe-path or place alongside this script."
    )


# ---------------------------------------------------------------------------
# Audio helpers
# ---------------------------------------------------------------------------

def load_wav_as_float32(path: str):
    """Return (samples_float32_np, sample_rate)."""
    sf = _import_soundfile()
    np = _import_numpy()
    audio, sr = sf.read(path, dtype="float32")
    if len(audio.shape) > 1:
        audio = np.mean(audio, axis=1)
    return audio, sr


def resample_to_16k(audio, sr: int):
    """Resample audio to 16 kHz if needed. Requires librosa."""
    if sr == 16000:
        return audio, 16000
    try:
        import librosa
        audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)
        return audio, 16000
    except ImportError:
        raise ImportError("librosa required for non-16kHz audio: pip install librosa")


def split_into_chunks(audio, sr: int, chunk_sec: float, overlap_sec: float = 0.0):
    """Split audio array into fixed-size chunks with optional overlap.

    Returns a list of numpy arrays, each of length chunk_sec * sr samples
    (last chunk may be shorter).
    """
    chunk_samples = int(chunk_sec * sr)
    step_samples = max(1, int((chunk_sec - overlap_sec) * sr))
    chunks = []
    pos = 0
    while pos < len(audio):
        chunk = audio[pos: pos + chunk_samples]
        chunks.append(chunk)
        pos += step_samples
    return chunks


def save_chunk_to_tempfile(chunk, sr: int) -> str:
    """Write a numpy float32 chunk to a temp WAV file. Returns path."""
    sf = _import_soundfile()
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    sf.write(tmp.name, chunk, sr, subtype="PCM_16")
    return tmp.name


def edit_distance_ratio(reference: str, hypothesis: str) -> float:
    """Normalised character-level edit distance in [0, 1].

    Returns 0.0 when both strings are empty (no difference).
    """
    ed = _import_editdistance()
    if not reference and not hypothesis:
        return 0.0
    max_len = max(len(reference), len(hypothesis), 1)
    return ed.eval(reference, hypothesis) / max_len


# ---------------------------------------------------------------------------
# Transcription helpers that call transcribe.py functions directly
# ---------------------------------------------------------------------------

def transcribe_wav(mod, wav_path: str, language: str = "en") -> dict:
    """Call transcribe_onnx (or huggingface fallback) on a wav file."""
    if mod.backend == "onnx":
        return mod.transcribe_onnx(wav_path, language=language)
    elif mod.backend == "huggingface":
        return mod.transcribe_huggingface(wav_path, language=language)
    else:
        raise RuntimeError(f"Unknown backend: {mod.backend}")


def transcribe_chunk(mod, chunk_audio, sr: int, language: str = "en") -> dict:
    """Write chunk to temp WAV, transcribe, clean up."""
    path = save_chunk_to_tempfile(chunk_audio, sr)
    try:
        return transcribe_wav(mod, path, language=language)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Test #1 — Chunk size boundary error rate
# ---------------------------------------------------------------------------

def run_test_1(mod, audio_files: list[str], language: str = "en") -> dict:
    """Compare chunked transcription (2s/3s/5s) against full-file baseline.

    For each audio file:
      1. Transcribe full file → baseline text
      2. Split into chunks of size N, transcribe each, concatenate
      3. Compute normalised edit distance between concatenated and baseline

    Reports mean edit distance per chunk size.
    Exit criterion: at least one size with mean edit distance < 10%.
    """
    chunk_sizes = [2.0, 3.0, 5.0]
    results_by_size: dict[float, list[float]] = {s: [] for s in chunk_sizes}

    for audio_path in audio_files:
        log.info(f"Test 1: processing {Path(audio_path).name}")
        try:
            audio, sr = load_wav_as_float32(audio_path)
            audio, sr = resample_to_16k(audio, sr)

            # Baseline: full-file transcription
            baseline_path = save_chunk_to_tempfile(audio, sr)
            try:
                baseline_result = transcribe_wav(mod, baseline_path, language=language)
            finally:
                try:
                    os.unlink(baseline_path)
                except OSError:
                    pass
            baseline_text = baseline_result.get("text", "").strip()
            log.info(f"  Baseline ({len(audio)/sr:.1f}s): '{baseline_text[:80]}'")

            for chunk_sec in chunk_sizes:
                chunks = split_into_chunks(audio, sr, chunk_sec=chunk_sec, overlap_sec=0.0)
                texts = []
                for chunk in chunks:
                    if len(chunk) / sr < 0.3:
                        # Too short — skip (model would hallucinate)
                        continue
                    result = transcribe_chunk(mod, chunk, sr, language=language)
                    texts.append(result.get("text", "").strip())
                concatenated = " ".join(t for t in texts if t).strip()
                dist = edit_distance_ratio(baseline_text, concatenated)
                results_by_size[chunk_sec].append(dist)
                log.info(f"  Chunk {chunk_sec}s: edit_dist={dist:.3f} — '{concatenated[:80]}'")

        except Exception as exc:
            log.warning(f"  Skipping {audio_path}: {exc}")

    summary = {}
    passed = False
    for chunk_sec in chunk_sizes:
        vals = results_by_size[chunk_sec]
        if vals:
            mean_dist = statistics.mean(vals)
            summary[f"chunk_{chunk_sec}s"] = {
                "mean_edit_distance": round(mean_dist, 4),
                "samples": len(vals),
                "passes_10pct_threshold": mean_dist < 0.10,
            }
            if mean_dist < 0.10:
                passed = True
        else:
            summary[f"chunk_{chunk_sec}s"] = {"error": "no valid samples"}

    return {
        "test": 1,
        "name": "chunk_boundary_error_rate",
        "exit_criterion": "at_least_one_chunk_size_edit_dist_lt_10pct",
        "passed": passed,
        "details": summary,
    }


# ---------------------------------------------------------------------------
# Test #2 — First-chunk latency
# ---------------------------------------------------------------------------

def run_test_2(mod, audio_files: list[str], language: str = "en") -> dict:
    """Measure end-to-end latency for first chunk (audio load → text out).

    For each of 2s / 3s / 5s chunk sizes, take the first chunk from the first
    available audio file and run 10 timed transcription calls. Report median.

    Exit criterion: median < 5s on M1 16GB. Median > 8s → V3 kill signal.
    """
    if not audio_files:
        return {"test": 2, "error": "no audio files provided"}

    # Use the first audio file for latency measurement
    audio_path = audio_files[0]
    log.info(f"Test 2: latency measurement using {Path(audio_path).name}")

    try:
        audio, sr = load_wav_as_float32(audio_path)
        audio, sr = resample_to_16k(audio, sr)
    except Exception as exc:
        return {"test": 2, "error": str(exc)}

    chunk_sizes = [2.0, 3.0, 5.0]
    num_runs = 10
    results_by_size = {}

    for chunk_sec in chunk_sizes:
        # Take only the first chunk
        chunk_samples = int(chunk_sec * sr)
        chunk = audio[:chunk_samples]
        if len(chunk) / sr < 0.3:
            results_by_size[f"chunk_{chunk_sec}s"] = {"error": "audio too short for chunk"}
            continue

        latencies = []
        for run in range(num_runs):
            t_start = time.perf_counter()
            try:
                result = transcribe_chunk(mod, chunk, sr, language=language)
            except Exception as exc:
                log.warning(f"  Run {run+1} failed: {exc}")
                continue
            elapsed = time.perf_counter() - t_start
            latencies.append(elapsed)
            log.info(f"  Chunk {chunk_sec}s run {run+1}/{num_runs}: {elapsed:.3f}s → '{result.get('text','')[:50]}'")

        if not latencies:
            results_by_size[f"chunk_{chunk_sec}s"] = {"error": "all runs failed"}
            continue

        median_s = statistics.median(latencies)
        results_by_size[f"chunk_{chunk_sec}s"] = {
            "median_latency_s": round(median_s, 3),
            "mean_latency_s": round(statistics.mean(latencies), 3),
            "min_latency_s": round(min(latencies), 3),
            "max_latency_s": round(max(latencies), 3),
            "runs": len(latencies),
            "passes_5s_threshold": median_s < 5.0,
            "kill_signal": median_s > 8.0,
        }

    best_median = None
    kill_triggered = False
    for size_key, data in results_by_size.items():
        if "median_latency_s" in data:
            m = data["median_latency_s"]
            if best_median is None or m < best_median:
                best_median = m
            if data.get("kill_signal"):
                kill_triggered = True

    passed = best_median is not None and best_median < 5.0

    return {
        "test": 2,
        "name": "first_chunk_latency",
        "exit_criterion": "median_lt_5s. gt_8s_all_sizes=V3_cancelled",
        "passed": passed,
        "kill_signal": kill_triggered,
        "best_median_latency_s": best_median,
        "details": results_by_size,
    }


# ---------------------------------------------------------------------------
# Test #3 — CPU utilization during 30s streaming session
# ---------------------------------------------------------------------------

def run_test_3(mod, audio_files: list[str], language: str = "en") -> dict:
    """Simulate 30s streaming: transcribe 10 × 3s chunks back-to-back.

    Uses psutil to record per-process CPU% at each inference step.
    Reports peak and sustained (all-window) CPU%.

    Exit criterion: sustained CPU < 80% on M1 16GB.
    Warning: any window > 90% → throttle/cancel needed.
    """
    psutil = _import_psutil()

    if not audio_files:
        return {"test": 3, "error": "no audio files provided"}

    audio_path = audio_files[0]
    log.info(f"Test 3: CPU utilization using {Path(audio_path).name}")

    try:
        audio, sr = load_wav_as_float32(audio_path)
        audio, sr = resample_to_16k(audio, sr)
    except Exception as exc:
        return {"test": 3, "error": str(exc)}

    chunk_sec = 3.0
    num_chunks = 10
    chunk_samples = int(chunk_sec * sr)

    # Pad audio if needed to get 10 chunks
    needed_samples = chunk_samples * num_chunks
    if len(audio) < needed_samples:
        import numpy as np
        repeats = (needed_samples // len(audio)) + 1
        audio = np.tile(audio, repeats)[:needed_samples]

    current_proc = psutil.Process()
    # Warm up psutil CPU measurement (first call returns 0.0 by design)
    current_proc.cpu_percent(interval=None)

    cpu_samples = []
    chunk_latencies = []
    texts = []

    log.info(f"Test 3: transcribing {num_chunks} chunks of {chunk_sec}s each (simulated 30s session)")

    for i in range(num_chunks):
        chunk = audio[i * chunk_samples: (i + 1) * chunk_samples]

        # Measure CPU% over this inference window
        cpu_before = current_proc.cpu_percent(interval=None)
        t_start = time.perf_counter()
        try:
            result = transcribe_chunk(mod, chunk, sr, language=language)
            texts.append(result.get("text", "").strip())
        except Exception as exc:
            log.warning(f"  Chunk {i+1} failed: {exc}")
            texts.append("")
        elapsed = time.perf_counter() - t_start
        cpu_after = current_proc.cpu_percent(interval=None)

        # Use the mid-point measurement as the representative sample
        cpu_sample = max(cpu_before, cpu_after)
        cpu_samples.append(cpu_sample)
        chunk_latencies.append(elapsed)
        log.info(f"  Chunk {i+1}/{num_chunks}: {elapsed:.2f}s, CPU={cpu_sample:.1f}%")

    valid_cpu = [c for c in cpu_samples if c > 0]
    if not valid_cpu:
        return {"test": 3, "error": "psutil returned no CPU measurements"}

    peak_cpu = max(valid_cpu)
    sustained_cpu = statistics.mean(valid_cpu)
    any_over_90 = any(c > 90.0 for c in valid_cpu)
    passed = sustained_cpu < 80.0

    return {
        "test": 3,
        "name": "cpu_utilization_30s_session",
        "exit_criterion": "sustained_cpu_lt_80pct. gt_90pct_any_window=throttle_needed",
        "passed": passed,
        "throttle_warning": any_over_90,
        "peak_cpu_pct": round(peak_cpu, 1),
        "sustained_mean_cpu_pct": round(sustained_cpu, 1),
        "per_chunk_cpu_pct": [round(c, 1) for c in cpu_samples],
        "per_chunk_latency_s": [round(l, 3) for l in chunk_latencies],
        "total_simulated_duration_s": num_chunks * chunk_sec,
    }


# ---------------------------------------------------------------------------
# Test #5 — Streaming vs full-pass difference
# ---------------------------------------------------------------------------

def run_test_5(mod, audio_files: list[str], language: str = "en") -> dict:
    """Compare streaming (3s chunks concatenated) vs full-file transcription.

    For each audio file:
      1. Full-file transcribe → baseline
      2. Split into 3s chunks, transcribe each, concatenate → streaming result
      3. Compute normalised character edit distance

    Spec target: average edit distance < 20%. > 40% → V3 cancelled.
    """
    chunk_sec = 3.0
    edit_distances = []
    per_file = []

    for audio_path in audio_files:
        log.info(f"Test 5: processing {Path(audio_path).name}")
        try:
            audio, sr = load_wav_as_float32(audio_path)
            audio, sr = resample_to_16k(audio, sr)

            # Full-file baseline
            baseline_path = save_chunk_to_tempfile(audio, sr)
            try:
                baseline_result = transcribe_wav(mod, baseline_path, language=language)
            finally:
                try:
                    os.unlink(baseline_path)
                except OSError:
                    pass
            baseline_text = baseline_result.get("text", "").strip()

            # Streaming: 3s chunks
            chunks = split_into_chunks(audio, sr, chunk_sec=chunk_sec, overlap_sec=0.0)
            streaming_texts = []
            for chunk in chunks:
                if len(chunk) / sr < 0.3:
                    continue
                result = transcribe_chunk(mod, chunk, sr, language=language)
                streaming_texts.append(result.get("text", "").strip())
            streaming_concat = " ".join(t for t in streaming_texts if t).strip()

            dist = edit_distance_ratio(baseline_text, streaming_concat)
            edit_distances.append(dist)
            per_file.append({
                "file": Path(audio_path).name,
                "duration_s": round(len(audio) / sr, 1),
                "num_chunks": len([c for c in chunks if len(c) / sr >= 0.3]),
                "edit_distance": round(dist, 4),
                "baseline_chars": len(baseline_text),
                "streaming_chars": len(streaming_concat),
                "baseline_preview": baseline_text[:80],
                "streaming_preview": streaming_concat[:80],
            })
            log.info(f"  edit_dist={dist:.3f} | baseline='{baseline_text[:60]}' | streaming='{streaming_concat[:60]}'")

        except Exception as exc:
            log.warning(f"  Skipping {audio_path}: {exc}")
            per_file.append({"file": Path(audio_path).name, "error": str(exc)})

    if not edit_distances:
        return {
            "test": 5,
            "name": "streaming_vs_fullpass_difference",
            "error": "no valid audio files processed",
            "passed": False,
        }

    avg_dist = statistics.mean(edit_distances)
    kill_signal = avg_dist > 0.40
    passed = avg_dist < 0.20

    return {
        "test": 5,
        "name": "streaming_vs_fullpass_difference",
        "exit_criterion": "avg_edit_dist_lt_20pct. gt_40pct=V3_cancelled",
        "passed": passed,
        "kill_signal": kill_signal,
        "avg_edit_distance": round(avg_dist, 4),
        "median_edit_distance": round(statistics.median(edit_distances), 4),
        "max_edit_distance": round(max(edit_distances), 4),
        "num_files": len(edit_distances),
        "per_file": per_file,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def load_model(mod, model_path: str):
    """Initialise the transcribe module's global model state."""
    result = mod.load_model(model_path)
    if isinstance(result, dict) and "error" in result:
        raise RuntimeError(f"Model load failed: {result['error']}")
    log.info(f"Model loaded. Backend: {mod.backend}")


def collect_audio_files(audio_dir: str) -> list[str]:
    """Return sorted list of .wav files in audio_dir."""
    d = Path(audio_dir)
    if not d.is_dir():
        raise FileNotFoundError(f"Audio directory not found: {audio_dir}")
    files = sorted(d.rglob("*.wav"))
    if not files:
        raise FileNotFoundError(f"No .wav files found in {audio_dir}")
    return [str(f) for f in files]


def main():
    parser = argparse.ArgumentParser(
        description="V3 Phase 0 Spike — streaming voice input validation"
    )
    parser.add_argument(
        "--model-path",
        required=True,
        help="Path to the ONNX model directory (contains onnx/ subdir)",
    )
    parser.add_argument(
        "--audio-dir",
        required=True,
        help="Directory containing .wav test files at 16 kHz mono",
    )
    parser.add_argument(
        "--test",
        default="all",
        choices=["1", "2", "3", "5", "all"],
        help="Which spike test to run (default: all)",
    )
    parser.add_argument(
        "--output",
        default="v3_phase0_report.json",
        help="Path for JSON report output (default: v3_phase0_report.json)",
    )
    parser.add_argument(
        "--language",
        default="en",
        help="Transcription language hint: 'en', 'zh', or 'auto' (default: en)",
    )
    parser.add_argument(
        "--transcribe-path",
        default=None,
        help="Explicit path to transcribe.py (default: same directory as this script)",
    )
    args = parser.parse_args()

    # Resolve transcribe.py
    transcribe_path = _resolve_transcribe_path(args.transcribe_path)
    log.info(f"Using transcribe.py at: {transcribe_path}")

    mod = _load_transcribe_module(transcribe_path)

    log.info(f"Loading model from: {args.model_path}")
    load_model(mod, args.model_path)

    audio_files = collect_audio_files(args.audio_dir)
    log.info(f"Found {len(audio_files)} audio file(s) in {args.audio_dir}")

    tests_to_run = (
        ["1", "2", "3", "5"] if args.test == "all" else [args.test]
    )

    report: dict[str, Any] = {
        "spike": "V3 Phase 0",
        "date": time.strftime("%Y-%m-%d %H:%M:%S"),
        "model_path": args.model_path,
        "audio_dir": args.audio_dir,
        "num_audio_files": len(audio_files),
        "language": args.language,
        "results": [],
        "kill_signals": [],
        "overall_pass": True,
    }

    test_dispatch = {
        "1": lambda: run_test_1(mod, audio_files, language=args.language),
        "2": lambda: run_test_2(mod, audio_files, language=args.language),
        "3": lambda: run_test_3(mod, audio_files, language=args.language),
        "5": lambda: run_test_5(mod, audio_files, language=args.language),
    }

    for test_id in tests_to_run:
        log.info(f"\n{'='*60}\nRunning Test #{test_id}\n{'='*60}")
        result = test_dispatch[test_id]()
        report["results"].append(result)

        if not result.get("passed", True):
            report["overall_pass"] = False
        if result.get("kill_signal"):
            report["kill_signals"].append(f"test_{test_id}")
            log.warning(f"⚠ KILL SIGNAL triggered by Test #{test_id} — check exit criteria")

    # Summary
    log.info("\n" + "="*60)
    log.info("SPIKE SUMMARY")
    log.info("="*60)
    for result in report["results"]:
        status = "PASS" if result.get("passed") else "FAIL"
        kill = " [KILL SIGNAL]" if result.get("kill_signal") else ""
        log.info(f"  Test #{result['test']} ({result.get('name', '?')}): {status}{kill}")
    if report["kill_signals"]:
        log.warning(f"Kill signals triggered: {report['kill_signals']}")
        log.warning("Review results carefully before proceeding with V3 implementation.")
    log.info(f"Overall: {'PASS' if report['overall_pass'] else 'FAIL'}")

    # Write report
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
    log.info(f"\nReport written to: {output_path}")

    return 0 if report["overall_pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
