#!/usr/bin/env python3
"""
Murmur transcription subprocess (ONNX Runtime backend).
Long-lived process. Reads JSON commands from stdin, writes JSON responses to stdout.
Logs to ~/Library/Application Support/Murmur/transcribe.log
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
log.info("=== Transcribe subprocess started (ONNX backend) ===")

processor = None
encoder_sess = None
decoder_sess = None
gen_config = None

NUM_DECODER_LAYERS = 8


def load_model(model_path: str):
    global processor, encoder_sess, decoder_sess, gen_config

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

    return {"status": "ok"}


def transcribe(wav_path: str, language: str = "en"):
    global processor, encoder_sess, decoder_sess, gen_config

    if processor is None or encoder_sess is None or decoder_sess is None:
        log.error("Transcribe called but model not loaded")
        return {"error": "Model not loaded"}

    import numpy as np
    from transformers.audio_utils import load_audio

    start = time.time()

    # Load and preprocess audio
    log.info(f"Loading audio from {wav_path}")
    audio = load_audio(wav_path, sampling_rate=16000)
    duration = len(audio) / 16000
    log.info(f"Audio: {len(audio)} samples, {duration:.2f}s")

    inputs = processor(audio, sampling_rate=16000, return_tensors="np", language=language)
    input_features = inputs["input_features"].astype(np.float32)
    log.info(f"Input features shape: {input_features.shape}, language: {language}")

    # Use decoder prompt from processor (includes language/punctuation tokens)
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

    # Init empty KV cache
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

        # Update KV cache
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

    # Language detection based on character ranges
    chinese_chars = sum(1 for c in text if "\u4e00" <= c <= "\u9fff")
    total_alpha = sum(1 for c in text if c.isalpha())
    language = "zh" if total_alpha > 0 and chinese_chars / max(total_alpha, 1) > 0.3 else "en"

    return {
        "text": text,
        "language": language,
        "duration_ms": elapsed_ms,
    }


def unload_model():
    global processor, encoder_sess, decoder_sess, gen_config

    processor = None
    encoder_sess = None
    decoder_sess = None
    gen_config = None

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
                response = transcribe(cmd["wav_path"], language=cmd.get("language", "en"))
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
