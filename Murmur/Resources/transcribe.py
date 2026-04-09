#!/usr/bin/env python3
"""
Murmur transcription subprocess.
Long-lived process. Reads JSON commands from stdin, writes JSON responses to stdout.
Logs to ~/Library/Application Support/Murmur/transcribe.log
"""

import json
import sys
import time
import os
import logging

# Set up file logging
log_dir = os.path.expanduser("~/Library/Application Support/Murmur")
os.makedirs(log_dir, exist_ok=True)
log_path = os.path.join(log_dir, "transcribe.log")

logging.basicConfig(
    filename=log_path,
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("murmur")
log.info("=== Transcribe subprocess started ===")

model = None
processor = None


def load_model(model_path: str):
    global model, processor

    import torch
    from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype = torch.float32

    log.info(f"Loading model from {model_path}")
    log.info(f"Device: {device}, dtype: {dtype}")
    log.info(f"PyTorch version: {torch.__version__}")
    log.info(f"MPS available: {torch.backends.mps.is_available()}")

    # List model files
    files = os.listdir(model_path)
    log.info(f"Model directory contents: {files}")

    t0 = time.time()
    processor = AutoProcessor.from_pretrained(model_path, trust_remote_code=True)
    log.info(f"Processor loaded in {time.time()-t0:.1f}s")

    t0 = time.time()
    model = AutoModelForSpeechSeq2Seq.from_pretrained(
        model_path,
        torch_dtype=dtype,
        trust_remote_code=True,
    )
    log.info(f"Model loaded in {time.time()-t0:.1f}s")

    t0 = time.time()
    model = model.to(device)
    log.info(f"Model moved to {device} in {time.time()-t0:.1f}s")

    # Log model info
    param_count = sum(p.numel() for p in model.parameters())
    log.info(f"Model parameters: {param_count/1e6:.0f}M")
    log.info(f"Model dtype: {next(model.parameters()).dtype}")

    return {"status": "ok"}


def transcribe(wav_path: str):
    global model, processor

    if model is None or processor is None:
        log.error("Transcribe called but model not loaded")
        return {"error": "Model not loaded"}

    import torch
    import soundfile as sf
    import numpy as np

    start = time.time()

    # Load audio
    log.info(f"Loading audio from {wav_path}")
    audio, sr = sf.read(wav_path)
    log.info(f"Audio loaded: shape={np.array(audio).shape}, sr={sr}, duration={len(audio)/sr:.2f}s")
    log.info(f"Audio stats: min={np.min(audio):.4f}, max={np.max(audio):.4f}, mean={np.mean(audio):.4f}, std={np.std(audio):.4f}")

    # Check for stereo -> convert to mono
    if len(np.array(audio).shape) > 1:
        log.info(f"Converting stereo to mono")
        audio = np.mean(audio, axis=1)

    if sr != 16000:
        log.info(f"Resampling from {sr}Hz to 16000Hz")
        import librosa
        audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)
        sr = 16000

    log.info(f"Final audio: {len(audio)} samples, {len(audio)/sr:.2f}s")

    # Process
    inputs = processor(
        audio,
        sampling_rate=sr,
        return_tensors="pt",
    )

    device = next(model.parameters()).device
    input_features = inputs.input_features.to(device=device, dtype=model.dtype)
    log.info(f"Input features shape: {input_features.shape}, dtype: {input_features.dtype}")

    t0 = time.time()
    with torch.no_grad():
        generated_ids = model.generate(
            input_features,
            max_new_tokens=448,
        )
    inference_time = time.time() - t0
    log.info(f"Inference took {inference_time:.2f}s, generated {generated_ids.shape[1]} tokens")

    text = processor.batch_decode(generated_ids, skip_special_tokens=True)[0].strip()
    log.info(f"Transcription: '{text[:200]}'")

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

    log.info("Model unloaded")
    return {"status": "ok"}


def main():
    log.info("Waiting for commands on stdin...")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        log.debug(f"Received: {line[:200]}")

        try:
            cmd = json.loads(line)
        except json.JSONDecodeError as e:
            response = {"error": f"Invalid JSON: {e}"}
            log.error(f"Invalid JSON: {e}")
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()
            continue

        action = cmd.get("cmd")
        log.info(f"Command: {action}")

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
            log.exception(f"Error handling command '{action}'")
            response = {"error": str(e)}

        log.debug(f"Response: {json.dumps(response)[:200]}")
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()

    log.info("Stdin closed, exiting")


if __name__ == "__main__":
    main()
