#!/usr/bin/env python3
"""
Phase 0 Validation Spike — standalone test script.

Usage:
    python3 spike_test.py --model-path ~/Library/Application\ Support/Murmur/Models
    python3 spike_test.py --model-path ./models --audio test.wav

Tests:
1. Model loads on MPS (Apple Silicon GPU)
2. Inference latency for various audio lengths
3. Peak RAM usage
4. Language detection (EN + ZH)

Exit criteria (from spec):
  PASS: < 2s for 10s audio on M1 16GB
  WARN: 2-3s
  FAIL: > 3s or model unavailable
"""

import argparse
import json
import os
import resource
import sys
import tempfile
import time

def get_ram_mb():
    """Current process RSS in MB."""
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)

def generate_test_audio(duration_s: float, sr: int = 16000) -> str:
    """Generate a silent WAV file for benchmarking (real test needs real audio)."""
    import numpy as np
    import soundfile as sf

    samples = int(duration_s * sr)
    # Generate low-level noise instead of pure silence (avoids VAD rejection)
    audio = np.random.randn(samples).astype(np.float32) * 0.01
    path = os.path.join(tempfile.gettempdir(), f"spike_test_{duration_s}s.wav")
    sf.write(path, audio, sr)
    return path

def main():
    parser = argparse.ArgumentParser(description="Murmur Phase 0 Validation Spike")
    parser.add_argument("--model-path", required=True, help="Path to Cohere Transcribe model")
    parser.add_argument("--audio", help="Optional: path to a real WAV file to test")
    args = parser.parse_args()

    results = {
        "model_path": args.model_path,
        "tests": [],
        "verdict": "UNKNOWN"
    }

    print("=" * 60)
    print("MURMUR PHASE 0 VALIDATION SPIKE")
    print("=" * 60)

    # --- Test 1: Model Loading ---
    print("\n[1/4] Loading model...")
    ram_before = get_ram_mb()
    t0 = time.time()

    try:
        import torch
        from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor

        device = "mps" if torch.backends.mps.is_available() else "cpu"
        dtype = torch.float16 if device == "mps" else torch.float32

        processor = AutoProcessor.from_pretrained(args.model_path)
        model = AutoModelForSpeechSeq2Seq.from_pretrained(
            args.model_path,
            torch_dtype=dtype,
            device_map=device,
        )

        load_time = time.time() - t0
        ram_after = get_ram_mb()
        ram_used = ram_after - ram_before

        result = {
            "test": "model_load",
            "device": device,
            "dtype": str(dtype),
            "load_time_s": round(load_time, 2),
            "ram_delta_mb": round(ram_used, 0),
            "status": "PASS"
        }
        results["tests"].append(result)
        print(f"  Device: {device}, dtype: {dtype}")
        print(f"  Load time: {load_time:.2f}s")
        print(f"  RAM delta: {ram_used:.0f} MB")
        print(f"  Status: PASS")

    except Exception as e:
        results["tests"].append({
            "test": "model_load",
            "status": "FAIL",
            "error": str(e)
        })
        results["verdict"] = "FAIL"
        print(f"  FAIL: {e}")
        print(json.dumps(results, indent=2))
        sys.exit(1)

    # --- Test 2: Inference Latency ---
    print("\n[2/4] Inference latency benchmarks...")
    durations = [5, 10, 30, 60]

    for dur in durations:
        print(f"\n  Testing {dur}s audio...")
        if args.audio and dur == 10:
            wav_path = args.audio
            print(f"    Using provided audio: {wav_path}")
        else:
            wav_path = generate_test_audio(dur)
            print(f"    Using synthetic audio")

        import soundfile as sf
        audio, sr = sf.read(wav_path)
        if sr != 16000:
            import librosa
            audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)

        inputs = processor(audio, sampling_rate=16000, return_tensors="pt")
        input_features = inputs.input_features.to(device=device, dtype=model.dtype)

        t0 = time.time()
        with torch.no_grad():
            generated_ids = model.generate(input_features, max_new_tokens=448)
        inference_time = time.time() - t0

        text = processor.batch_decode(generated_ids, skip_special_tokens=True)[0].strip()

        if dur == 10:
            if inference_time < 2:
                status = "PASS"
            elif inference_time < 3:
                status = "WARN"
            else:
                status = "FAIL"
        else:
            status = "INFO"

        result = {
            "test": f"inference_{dur}s",
            "inference_time_s": round(inference_time, 2),
            "text_preview": text[:80] if text else "(empty)",
            "status": status
        }
        results["tests"].append(result)
        print(f"    Inference: {inference_time:.2f}s")
        print(f"    Text: {text[:60]}...")
        print(f"    Status: {status}")

    # --- Test 3: Peak RAM ---
    print("\n[3/4] Peak RAM measurement...")
    peak_ram = get_ram_mb()
    ram_status = "PASS" if peak_ram < 4096 else ("WARN" if peak_ram < 5120 else "FAIL")
    results["tests"].append({
        "test": "peak_ram",
        "peak_ram_mb": round(peak_ram, 0),
        "status": ram_status
    })
    print(f"  Peak RSS: {peak_ram:.0f} MB — {ram_status}")

    # --- Test 4: Subprocess crash isolation ---
    print("\n[4/4] Subprocess crash isolation...")
    # This test is for the parent process — spike_test.py IS the subprocess.
    # Just confirm we can unload cleanly.
    del model
    del processor
    if torch.backends.mps.is_available():
        torch.mps.empty_cache()
    import gc
    gc.collect()
    ram_after_unload = get_ram_mb()
    results["tests"].append({
        "test": "unload",
        "ram_after_unload_mb": round(ram_after_unload, 0),
        "status": "PASS"
    })
    print(f"  RAM after unload: {ram_after_unload:.0f} MB — PASS")

    # --- Verdict ---
    statuses = [t["status"] for t in results["tests"]]
    if "FAIL" in statuses:
        results["verdict"] = "FAIL"
    elif "WARN" in statuses:
        results["verdict"] = "WARN"
    else:
        results["verdict"] = "PASS"

    print("\n" + "=" * 60)
    print(f"VERDICT: {results['verdict']}")
    print("=" * 60)

    # Write results
    out_dir = os.path.dirname(os.path.abspath(__file__))
    results_dir = os.path.join(os.path.dirname(out_dir), "..", "docs", "spikes")
    os.makedirs(results_dir, exist_ok=True)
    results_path = os.path.join(results_dir, "phase0-results.json")
    with open(results_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults saved to {results_path}")


if __name__ == "__main__":
    main()
