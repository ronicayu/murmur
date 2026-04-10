#!/usr/bin/env python3
"""
Murmur transcription subprocess — supports both ONNX and HuggingFace (PyTorch) backends.
Long-lived process. Reads JSON commands from stdin, writes JSON responses to stdout.
Logs to ~/Library/Application Support/Murmur/transcribe.log

Backend is auto-detected from model directory contents:
  - If onnx/ subdir with .onnx files exists -> ONNX Runtime backend
  - Otherwise -> HuggingFace PyTorch backend
"""

import json
import sys
import time
import os
import logging

# Prevent OMP duplicate library crash on macOS with Homebrew Python + torch
os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
os.environ.setdefault("OMP_NUM_THREADS", "4")

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

# Shared state
backend = None  # "onnx", "huggingface", or "whisper"
processor = None

# ONNX-specific state
encoder_sess = None
decoder_sess = None
gen_config = None
NUM_DECODER_LAYERS = 8

# HuggingFace/Whisper-specific state
hf_model = None


def detect_backend(model_path: str) -> str:
    """Auto-detect backend from model directory contents."""
    onnx_dir = os.path.join(model_path, "onnx")
    if os.path.isdir(onnx_dir) and any(f.endswith(".onnx") for f in os.listdir(onnx_dir)):
        return "onnx"
    # Detect Whisper by checking config.json for model_type
    config_path = os.path.join(model_path, "config.json")
    if os.path.isfile(config_path):
        try:
            with open(config_path) as f:
                config = json.load(f)
            if config.get("model_type") == "whisper":
                return "whisper"
        except Exception:
            pass
    return "huggingface"


def load_model(model_path: str):
    detected = detect_backend(model_path)
    log.info(f"Detected backend: {detected}")
    if detected == "onnx":
        return load_model_onnx(model_path)
    elif detected == "whisper":
        return load_model_whisper(model_path)
    else:
        return load_model_huggingface(model_path)


# ---------------------------------------------------------------------------
# ONNX Runtime backend
# ---------------------------------------------------------------------------

def load_model_onnx(model_path: str):
    global backend, processor, encoder_sess, decoder_sess, gen_config

    import onnxruntime as ort
    from transformers import CohereAsrProcessor

    log.info(f"Loading ONNX model from {model_path}")

    onnx_dir = os.path.join(model_path, "onnx")
    if not os.path.isdir(onnx_dir):
        return {"error": f"ONNX directory not found: {onnx_dir}"}

    t0 = time.time()
    processor = CohereAsrProcessor.from_pretrained(model_path)
    log.info(f"Processor loaded in {time.time()-t0:.1f}s")

    with open(os.path.join(model_path, "generation_config.json")) as f:
        gen_config = json.load(f)
    log.info(f"Generation config: decoder_start={gen_config.get('decoder_start_token_id')}, eos={gen_config.get('eos_token_id')}")

    sess_opts = ort.SessionOptions()
    sess_opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    sess_opts.intra_op_num_threads = 4
    providers = ["CPUExecutionProvider"]

    t0 = time.time()
    encoder_sess = ort.InferenceSession(
        os.path.join(onnx_dir, "encoder_model_q4f16.onnx"),
        sess_opts,
        providers=providers,
    )
    log.info(f"Encoder loaded in {time.time()-t0:.1f}s")

    t0 = time.time()
    decoder_sess = ort.InferenceSession(
        os.path.join(onnx_dir, "decoder_model_merged_q4f16.onnx"),
        sess_opts,
        providers=providers,
    )
    log.info(f"Decoder loaded in {time.time()-t0:.1f}s")

    log.info(f"ONNX Runtime version: {ort.__version__}")
    log.info(f"Providers: {providers}")

    backend = "onnx"
    return {"status": "ok"}


def transcribe_onnx(wav_path: str, language: str = "en"):
    global processor, encoder_sess, decoder_sess, gen_config

    import numpy as np
    from transformers.audio_utils import load_audio

    start = time.time()

    log.info(f"Loading audio from {wav_path}")
    audio = load_audio(wav_path, sampling_rate=16000)
    duration = len(audio) / 16000
    log.info(f"Audio: {len(audio)} samples, {duration:.2f}s")

    # CohereAsrProcessor requires an explicit language argument.
    # When "auto", default to "en" — the model transcribes multilingual
    # content regardless, and post-hoc detection identifies the actual language.
    proc_lang = "en" if language == "auto" else language
    inputs = processor(audio, sampling_rate=16000, return_tensors="np", language=proc_lang)
    input_features = inputs["input_features"].astype(np.float32)
    log.info(f"Input features shape: {input_features.shape}, language: {language}")

    decoder_prompt = inputs["decoder_input_ids"].flatten().tolist()
    log.info(f"Decoder prompt IDs: {decoder_prompt}")

    # Encode
    t0 = time.time()
    enc_out = encoder_sess.run(None, {"input_features": input_features})
    encoder_hidden = enc_out[0]
    log.info(f"Encoder: {time.time()-t0:.2f}s, shape: {encoder_hidden.shape}")

    # Decode (autoregressive with KV cache)
    eos_id = gen_config["eos_token_id"]
    generated = list(decoder_prompt)

    past_kv = {}
    for i in range(NUM_DECODER_LAYERS):
        for part in ("decoder", "encoder"):
            past_kv[f"past_key_values.{i}.{part}.key"] = np.zeros((1, 8, 0, 128), dtype=np.float16)
            past_kv[f"past_key_values.{i}.{part}.value"] = np.zeros((1, 8, 0, 128), dtype=np.float16)

    t0 = time.time()
    use_cache = False
    max_tokens = 448

    for step in range(max_tokens):
        if not use_cache:
            cur_ids = np.array([generated], dtype=np.int64)
            cur_len = len(generated)
        else:
            cur_ids = np.array([[generated[-1]]], dtype=np.int64)
            cur_len = 1

        past_dec_len = past_kv["past_key_values.0.decoder.key"].shape[2]

        feed = {
            "input_ids": cur_ids,
            "attention_mask": np.ones((1, past_dec_len + cur_len), dtype=np.int64),
            "position_ids": np.arange(past_dec_len, past_dec_len + cur_len, dtype=np.int64).reshape(1, -1),
            "num_logits_to_keep": np.array(1, dtype=np.int64),
            "encoder_hidden_states": encoder_hidden,
        }
        feed.update(past_kv)

        outputs = decoder_sess.run(None, feed)
        logits = outputs[0]
        next_token = int(np.argmax(logits[0, -1]))
        generated.append(next_token)

        if next_token == eos_id:
            break

        idx = 1
        for i in range(NUM_DECODER_LAYERS):
            past_kv[f"past_key_values.{i}.decoder.key"] = outputs[idx].astype(np.float16)
            past_kv[f"past_key_values.{i}.decoder.value"] = outputs[idx + 1].astype(np.float16)
            past_kv[f"past_key_values.{i}.encoder.key"] = outputs[idx + 2].astype(np.float16)
            past_kv[f"past_key_values.{i}.encoder.value"] = outputs[idx + 3].astype(np.float16)
            idx += 4

        use_cache = True

    decode_time = time.time() - t0
    log.info(f"Decoder: {decode_time:.2f}s, {len(generated)} tokens")

    text = processor.tokenizer.decode(generated, skip_special_tokens=True).strip()
    log.info(f"Transcription: '{text[:200]}'")

    elapsed_ms = int((time.time() - start) * 1000)

    chinese_chars = sum(1 for c in text if "\u4e00" <= c <= "\u9fff")
    total_alpha = sum(1 for c in text if c.isalpha())
    detected_lang = "zh" if total_alpha > 0 and chinese_chars / max(total_alpha, 1) > 0.3 else "en"

    return {"text": text, "language": detected_lang, "duration_ms": elapsed_ms}


# ---------------------------------------------------------------------------
# HuggingFace PyTorch backend
# ---------------------------------------------------------------------------

def load_model_huggingface(model_path: str):
    global backend, hf_model, processor

    import torch
    from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype = torch.float32

    log.info(f"Loading HuggingFace model from {model_path}")
    log.info(f"Device: {device}, dtype: {dtype}")
    log.info(f"PyTorch version: {torch.__version__}")
    log.info(f"MPS available: {torch.backends.mps.is_available()}")

    files = os.listdir(model_path)
    log.info(f"Model directory contents: {files}")

    t0 = time.time()
    processor = AutoProcessor.from_pretrained(model_path, trust_remote_code=True)
    log.info(f"Processor loaded in {time.time()-t0:.1f}s")

    t0 = time.time()
    hf_model = AutoModelForSpeechSeq2Seq.from_pretrained(
        model_path,
        torch_dtype=dtype,
        trust_remote_code=True,
    )
    log.info(f"Model loaded in {time.time()-t0:.1f}s")

    t0 = time.time()
    hf_model = hf_model.to(device)
    log.info(f"Model moved to {device} in {time.time()-t0:.1f}s")

    param_count = sum(p.numel() for p in hf_model.parameters())
    log.info(f"Model parameters: {param_count/1e6:.0f}M")
    log.info(f"Model dtype: {next(hf_model.parameters()).dtype}")

    backend = "huggingface"
    return {"status": "ok"}


def transcribe_huggingface(wav_path: str, language: str = "en"):
    global hf_model, processor

    import torch
    import soundfile as sf
    import numpy as np

    start = time.time()

    log.info(f"Loading audio from {wav_path}")
    audio, sr = sf.read(wav_path)
    log.info(f"Audio loaded: shape={np.array(audio).shape}, sr={sr}, duration={len(audio)/sr:.2f}s")

    if len(np.array(audio).shape) > 1:
        log.info("Converting stereo to mono")
        audio = np.mean(audio, axis=1)

    if sr != 16000:
        log.info(f"Resampling from {sr}Hz to 16000Hz")
        import librosa
        audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)
        sr = 16000

    log.info(f"Final audio: {len(audio)} samples, {len(audio)/sr:.2f}s")

    # CohereAsrProcessor requires explicit language; default to "en" for auto-detect
    proc_lang = "en" if language == "auto" else language
    inputs = processor(audio, sampling_rate=sr, return_tensors="pt", language=proc_lang)

    device = next(hf_model.parameters()).device
    input_features = inputs.input_features.to(device=device, dtype=hf_model.dtype)
    log.info(f"Input features shape: {input_features.shape}, dtype: {input_features.dtype}")

    t0 = time.time()
    with torch.no_grad():
        generated_ids = hf_model.generate(input_features, max_new_tokens=448)
    inference_time = time.time() - t0
    log.info(f"Inference took {inference_time:.2f}s, generated {generated_ids.shape[1]} tokens")

    text = processor.batch_decode(generated_ids, skip_special_tokens=True)[0].strip()
    log.info(f"Transcription: '{text[:200]}'")

    elapsed_ms = int((time.time() - start) * 1000)

    chinese_chars = sum(1 for c in text if "\u4e00" <= c <= "\u9fff")
    total_alpha = sum(1 for c in text if c.isalpha())
    detected_lang = "zh" if total_alpha > 0 and chinese_chars / max(total_alpha, 1) > 0.3 else "en"

    return {"text": text, "language": detected_lang, "duration_ms": elapsed_ms}


# ---------------------------------------------------------------------------
# Whisper backend
# ---------------------------------------------------------------------------

def load_model_whisper(model_path: str):
    global backend, hf_model, processor

    import torch
    from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype = torch.float16 if device == "mps" else torch.float32

    log.info(f"Loading Whisper model from {model_path}")
    log.info(f"Device: {device}, dtype: {dtype}")

    t0 = time.time()
    processor = AutoProcessor.from_pretrained(model_path)
    log.info(f"Processor loaded in {time.time()-t0:.1f}s")

    t0 = time.time()
    hf_model = AutoModelForSpeechSeq2Seq.from_pretrained(
        model_path,
        torch_dtype=dtype,
        low_cpu_mem_usage=True,
    )
    log.info(f"Model loaded in {time.time()-t0:.1f}s")

    t0 = time.time()
    hf_model = hf_model.to(device)
    log.info(f"Model moved to {device} in {time.time()-t0:.1f}s")

    param_count = sum(p.numel() for p in hf_model.parameters())
    log.info(f"Model parameters: {param_count/1e6:.0f}M")

    backend = "whisper"
    return {"status": "ok"}


def transcribe_whisper(wav_path: str, language: str = "en"):
    global hf_model, processor

    import torch
    import soundfile as sf
    import numpy as np

    start = time.time()

    log.info(f"Loading audio from {wav_path}")
    audio, sr = sf.read(wav_path)

    if len(np.array(audio).shape) > 1:
        audio = np.mean(audio, axis=1)

    if sr != 16000:
        import librosa
        audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)
        sr = 16000

    log.info(f"Audio: {len(audio)} samples, {len(audio)/sr:.2f}s")

    inputs = processor(audio, sampling_rate=sr, return_tensors="pt")

    device = next(hf_model.parameters()).device
    input_features = inputs.input_features.to(device=device, dtype=hf_model.dtype)

    # Whisper supports language and task natively in generate()
    # Whisper's max_target_positions is 448 total (including prompt tokens)
    generate_kwargs = {"max_new_tokens": 440, "task": "transcribe"}
    if language and language != "auto":
        generate_kwargs["language"] = language

    t0 = time.time()
    with torch.no_grad():
        generated_ids = hf_model.generate(input_features, **generate_kwargs)
    inference_time = time.time() - t0
    log.info(f"Inference took {inference_time:.2f}s, generated {generated_ids.shape[1]} tokens")

    text = processor.batch_decode(generated_ids, skip_special_tokens=True)[0].strip()
    log.info(f"Transcription: '{text[:200]}'")

    elapsed_ms = int((time.time() - start) * 1000)

    chinese_chars = sum(1 for c in text if "\u4e00" <= c <= "\u9fff")
    total_alpha = sum(1 for c in text if c.isalpha())
    detected_lang = "zh" if total_alpha > 0 and chinese_chars / max(total_alpha, 1) > 0.3 else "en"

    return {"text": text, "language": detected_lang, "duration_ms": elapsed_ms}


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def transcribe(wav_path: str, language: str = "en"):
    if backend == "onnx":
        if encoder_sess is None or decoder_sess is None:
            return {"error": "Model not loaded"}
        return transcribe_onnx(wav_path, language)
    elif backend == "huggingface":
        if hf_model is None:
            return {"error": "Model not loaded"}
        return transcribe_huggingface(wav_path, language)
    elif backend == "whisper":
        if hf_model is None:
            return {"error": "Model not loaded"}
        return transcribe_whisper(wav_path, language)
    else:
        return {"error": "No model loaded"}


def unload_model():
    global backend, processor, encoder_sess, decoder_sess, gen_config, hf_model

    if backend in ("huggingface", "whisper") and hf_model is not None:
        import torch
        hf_model = None
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()

    processor = None
    encoder_sess = None
    decoder_sess = None
    gen_config = None
    hf_model = None
    backend = None

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
                response = transcribe(cmd["wav_path"], language=cmd.get("language", "auto"))
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
