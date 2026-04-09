#!/usr/bin/env python3
"""
Murmur transcription subprocess.
Long-lived process. Reads JSON commands from stdin, writes JSON responses to stdout.

Protocol:
  → {"cmd":"load","model_path":"/path/to/model"}      ← {"status":"ok"}
  → {"cmd":"transcribe","wav_path":"/tmp/audio.wav"}   ← {"text":"...","language":"en","duration_ms":1200}
  → {"cmd":"unload"}                                    ← {"status":"ok"}
"""

import json
import sys
import time
import os

model = None
processor = None


def load_model(model_path: str):
    global model, processor

    import torch
    from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    # Use float32 — float16 on MPS causes c10 conversion errors with some ops
    dtype = torch.float32

    processor = AutoProcessor.from_pretrained(model_path, trust_remote_code=True)
    model = AutoModelForSpeechSeq2Seq.from_pretrained(
        model_path,
        torch_dtype=dtype,
        trust_remote_code=True,
    )
    model = model.to(device)

    return {"status": "ok"}


def transcribe(wav_path: str):
    global model, processor

    if model is None or processor is None:
        return {"error": "Model not loaded"}

    import torch
    import soundfile as sf

    start = time.time()

    # Load audio
    audio, sr = sf.read(wav_path)
    if sr != 16000:
        import librosa
        audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)
        sr = 16000

    # Process
    inputs = processor(
        audio,
        sampling_rate=sr,
        return_tensors="pt",
    )

    device = next(model.parameters()).device
    input_features = inputs.input_features.to(device=device, dtype=model.dtype)

    with torch.no_grad():
        generated_ids = model.generate(
            input_features,
            max_new_tokens=448,
        )

    text = processor.batch_decode(generated_ids, skip_special_tokens=True)[0].strip()

    elapsed_ms = int((time.time() - start) * 1000)

    # Simple language detection based on character ranges
    chinese_chars = sum(1 for c in text if '\u4e00' <= c <= '\u9fff')
    total_alpha = sum(1 for c in text if c.isalpha())
    language = "zh" if total_alpha > 0 and chinese_chars / max(total_alpha, 1) > 0.3 else "en"

    return {
        "text": text,
        "language": language,
        "duration_ms": elapsed_ms,
    }


def unload_model():
    global model, processor

    import torch

    model = None
    processor = None
    if torch.backends.mps.is_available():
        torch.mps.empty_cache()
    import gc
    gc.collect()

    return {"status": "ok"}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            cmd = json.loads(line)
        except json.JSONDecodeError as e:
            response = {"error": f"Invalid JSON: {e}"}
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()
            continue

        action = cmd.get("cmd")

        try:
            if action == "load":
                response = load_model(cmd["model_path"])
            elif action == "transcribe":
                response = transcribe(cmd["wav_path"])
            elif action == "unload":
                response = unload_model()
            else:
                response = {"error": f"Unknown command: {action}"}
        except Exception as e:
            response = {"error": str(e)}

        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
