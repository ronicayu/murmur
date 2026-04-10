#!/usr/bin/env python3
"""
Phase 0 — Test Audio Preparation.

Downloads and prepares test audio for Phase 0 spike:
  - EN single-speaker: LibriSpeech test-clean subset
  - ZH single-speaker: AISHELL-1 test subset
  - Synthetic long files: 5/15/30/60/120 min by concatenation
  - m4a and .ogg format probe files

Usage:
    python3 prepare_test_audio.py --output-dir ./test_audio [--no-librispeech] [--no-aishell]

Output structure:
    test_audio/
        single_speaker/
            en/   (5 EN .wav + .txt reference transcripts)
            zh/   (5 ZH .wav + .txt reference transcripts)
        multi_speaker/
            en/   (5 EN multi-speaker .wav + .txt)
            zh/   (5 ZH multi-speaker .wav + .txt)
        duration/
            5min.wav
            15min.wav
            30min.wav
            60min.wav
            120min.wav
        _test_probe.m4a
        _test_probe.ogg

Dependencies: requests, soundfile, numpy, tqdm
Optional: ffmpeg (for m4a/ogg conversion, multi-speaker mixing)
"""

import argparse
import json
import os
import sys
import subprocess
import logging
import tarfile
import urllib.request
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("prepare_audio")

# ---------------------------------------------------------------------------
# LibriSpeech — English single-speaker
# ---------------------------------------------------------------------------

LIBRISPEECH_URL = "https://www.openslr.org/resources/12/test-clean.tar.gz"
LIBRISPEECH_ARCHIVE = "librispeech_test_clean.tar.gz"
LIBRISPEECH_MAX_FILES = 5  # 5 EN utterances for Test 3


def _download_with_progress(url: str, dest_path: str):
    log.info(f"Downloading {url} -> {dest_path}")
    try:
        import tqdm
        with tqdm.tqdm(unit="B", unit_scale=True, miniters=1, desc=os.path.basename(dest_path)) as t:
            def reporthook(block_num, block_size, total_size):
                if total_size > 0:
                    t.total = total_size
                t.update(block_num * block_size - t.n)
            urllib.request.urlretrieve(url, dest_path, reporthook=reporthook)
    except ImportError:
        urllib.request.urlretrieve(url, dest_path)
    log.info(f"Downloaded {os.path.getsize(dest_path) / 1e6:.1f} MB")


def download_librispeech(output_dir: str):
    """Download LibriSpeech test-clean, extract 5 EN utterances with transcripts."""
    en_dir = os.path.join(output_dir, "single_speaker", "en")
    os.makedirs(en_dir, exist_ok=True)

    existing = [f for f in os.listdir(en_dir) if f.endswith(".wav")]
    if len(existing) >= LIBRISPEECH_MAX_FILES:
        log.info(f"LibriSpeech: {len(existing)} files already present, skipping download")
        return

    archive_path = os.path.join(output_dir, LIBRISPEECH_ARCHIVE)
    if not os.path.exists(archive_path):
        _download_with_progress(LIBRISPEECH_URL, archive_path)

    log.info("Extracting LibriSpeech...")
    extracted_dir = os.path.join(output_dir, "_librispeech_extracted")
    os.makedirs(extracted_dir, exist_ok=True)

    with tarfile.open(archive_path, "r:gz") as tar:
        # Extract only FLAC audio and transcript files
        members = [m for m in tar.getmembers()
                   if m.name.endswith(".flac") or m.name.endswith(".trans.txt")]
        tar.extractall(extracted_dir, members=members)

    _collect_librispeech_utterances(extracted_dir, en_dir, max_files=LIBRISPEECH_MAX_FILES)
    log.info(f"LibriSpeech: prepared {LIBRISPEECH_MAX_FILES} EN utterances in {en_dir}")


def _collect_librispeech_utterances(src_dir: str, dest_dir: str, max_files: int):
    """Convert FLAC to WAV, copy alongside .txt reference transcripts."""
    import glob

    trans_files = glob.glob(os.path.join(src_dir, "**", "*.trans.txt"), recursive=True)
    utterances = []
    for trans_path in trans_files:
        with open(trans_path) as f:
            for line in f:
                parts = line.strip().split(" ", 1)
                if len(parts) == 2:
                    utterance_id, text = parts
                    flac_path = os.path.join(os.path.dirname(trans_path), utterance_id + ".flac")
                    if os.path.exists(flac_path):
                        utterances.append((utterance_id, flac_path, text))

    for utterance_id, flac_path, text in utterances[:max_files]:
        wav_path = os.path.join(dest_dir, utterance_id + ".wav")
        txt_path = os.path.join(dest_dir, utterance_id + ".txt")

        # Convert FLAC to WAV 16kHz mono
        ret = subprocess.run(
            ["ffmpeg", "-y", "-i", flac_path, "-ar", "16000", "-ac", "1", wav_path],
            capture_output=True,
        )
        if ret.returncode != 0:
            # Try with soundfile if ffmpeg unavailable
            try:
                import soundfile as sf
                import numpy as np
                audio, sr = sf.read(flac_path)
                if len(audio.shape) > 1:
                    audio = np.mean(audio, axis=1)
                if sr != 16000:
                    import librosa
                    audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)
                sf.write(wav_path, audio, 16000)
            except Exception as e:
                log.warning(f"Could not convert {flac_path}: {e}")
                continue

        with open(txt_path, "w") as f:
            f.write(text.lower())

        log.info(f"  Prepared: {utterance_id}")


# ---------------------------------------------------------------------------
# AISHELL-1 — Chinese single-speaker
# ---------------------------------------------------------------------------

AISHELL_URL = "https://www.openslr.org/resources/33/data_aishell.tgz"
AISHELL_ARCHIVE = "aishell.tgz"
AISHELL_MAX_FILES = 5


AISHELL_MIN_FREE_DISK_BYTES = 20 * 1024 ** 3  # 20 GB


def download_aishell(output_dir: str):
    """Download AISHELL-1 test subset, extract 5 ZH utterances."""
    zh_dir = os.path.join(output_dir, "single_speaker", "zh")
    os.makedirs(zh_dir, exist_ok=True)

    existing = [f for f in os.listdir(zh_dir) if f.endswith(".wav")]
    if len(existing) >= AISHELL_MAX_FILES:
        log.info(f"AISHELL: {len(existing)} files already present, skipping download")
        return

    archive_path = os.path.join(output_dir, AISHELL_ARCHIVE)
    if not os.path.exists(archive_path):
        import shutil
        free_bytes = shutil.disk_usage(output_dir).free
        if free_bytes < AISHELL_MIN_FREE_DISK_BYTES:
            free_gb = free_bytes / 1024 ** 3
            log.warning(
                f"Only {free_gb:.1f} GB free — AISHELL archive requires ~15 GB plus extraction space. "
                f"Use --no-aishell to skip, or free at least 20 GB before proceeding."
            )
            raise RuntimeError(
                f"Insufficient disk space for AISHELL download: {free_gb:.1f} GB free, 20 GB needed"
            )
        log.info("AISHELL archive is large (~15GB). Download may take a while.")
        _download_with_progress(AISHELL_URL, archive_path)

    log.info("Extracting AISHELL...")
    extracted_dir = os.path.join(output_dir, "_aishell_extracted")
    os.makedirs(extracted_dir, exist_ok=True)

    # Extract only the test split
    with tarfile.open(archive_path, "r:gz") as tar:
        members = [m for m in tar.getmembers()
                   if "test" in m.name and (m.name.endswith(".wav") or "transcript" in m.name)]
        tar.extractall(extracted_dir, members=members)

    _collect_aishell_utterances(extracted_dir, zh_dir, max_files=AISHELL_MAX_FILES)
    log.info(f"AISHELL: prepared {AISHELL_MAX_FILES} ZH utterances in {zh_dir}")


def _collect_aishell_utterances(src_dir: str, dest_dir: str, max_files: int):
    import glob

    # AISHELL transcript: data_aishell/transcript/aishell_transcript_v0.8.txt
    transcript_files = glob.glob(os.path.join(src_dir, "**", "*transcript*.txt"), recursive=True)
    transcripts: dict[str, str] = {}
    for tf in transcript_files:
        with open(tf, encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split(" ", 1)
                if len(parts) == 2:
                    utt_id, text = parts
                    transcripts[utt_id] = text

    wav_files = glob.glob(os.path.join(src_dir, "**", "test", "**", "*.wav"), recursive=True)
    count = 0
    for wav_src in wav_files:
        if count >= max_files:
            break
        utt_id = os.path.splitext(os.path.basename(wav_src))[0]
        if utt_id not in transcripts:
            continue

        wav_dest = os.path.join(dest_dir, utt_id + ".wav")
        txt_dest = os.path.join(dest_dir, utt_id + ".txt")

        # Resample to 16kHz mono
        ret = subprocess.run(
            ["ffmpeg", "-y", "-i", wav_src, "-ar", "16000", "-ac", "1", wav_dest],
            capture_output=True,
        )
        if ret.returncode != 0:
            try:
                import soundfile as sf
                import numpy as np
                audio, sr = sf.read(wav_src)
                if len(audio.shape) > 1:
                    audio = np.mean(audio, axis=1)
                if sr != 16000:
                    import librosa
                    audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)
                sf.write(wav_dest, audio, 16000)
            except Exception as e:
                log.warning(f"Could not prepare {wav_src}: {e}")
                continue

        with open(txt_dest, "w", encoding="utf-8") as f:
            f.write(transcripts[utt_id])

        log.info(f"  Prepared: {utt_id}")
        count += 1


# ---------------------------------------------------------------------------
# Synthetic long files
# ---------------------------------------------------------------------------

DURATION_TARGETS_MINUTES = [5, 15, 30, 60, 120]

# ---------------------------------------------------------------------------
# Noise augmentation — partial mitigation for DA疑一 (clean speech limitation)
# ---------------------------------------------------------------------------

def _add_noise_augmentation(audio, sr: int, snr_db: float = 17.5) -> "numpy.ndarray":
    """
    Add additive white Gaussian noise at target SNR and a simple room-reverb
    simulation via short exponential decay convolution.

    SNR range 15-20 dB approximates a nearby-mic office environment.
    This is imperfect compared to real meeting recordings but substantially
    better than clean LibriSpeech for testing model robustness.

    Limitations acknowledged (per DA challenge):
    - No overlapping speakers
    - No far-field microphone simulation
    - Not a substitute for AMI Corpus or real meeting audio
    Results should be interpreted as 'noisy single-speaker', not 'meeting audio'.
    """
    import numpy as np

    signal_power = float(np.mean(audio ** 2))
    if signal_power == 0:
        return audio

    # Additive noise at target SNR
    noise_power = signal_power / (10 ** (snr_db / 10))
    noise = np.random.randn(len(audio)).astype(np.float32) * float(np.sqrt(noise_power))
    noisy = audio + noise

    # Simple room reverb: convolve with short exponential-decay IR (~120ms)
    reverb_len = int(sr * 0.12)
    decay = np.exp(-4.0 * np.arange(reverb_len) / reverb_len).astype(np.float32)
    decay /= decay.sum()
    reverbed = np.convolve(noisy, decay, mode="full")[:len(noisy)]

    # Normalise to prevent clipping
    peak = float(np.max(np.abs(reverbed)))
    if peak > 0.95:
        reverbed = reverbed * (0.95 / peak)

    return reverbed


def generate_duration_files(output_dir: str, source_wav_dir: str,
                             noise_augment: bool = True, snr_db: float = 17.5):
    """Concatenate source WAVs to generate synthetic long audio files.

    Warning: duration files are generated by tiling source audio.
    WER/SBER metrics on these files may be optimistic because:
    - The same phoneme patterns repeat, reducing model confusion
    - No background noise (unless noise_augment=True)
    - Single speaker throughout
    This is documented in manifest.json as 'tiled_source'.
    """
    duration_dir = os.path.join(output_dir, "duration")
    os.makedirs(duration_dir, exist_ok=True)

    import glob
    import soundfile as sf
    import numpy as np

    # Collect all available WAV files as source material
    source_files = sorted(glob.glob(os.path.join(source_wav_dir, "**", "*.wav"), recursive=True))
    if not source_files:
        log.warning("No source WAV files found for duration file generation")
        return

    # Load all source audio into one long stream
    log.info(f"Building source pool from {len(source_files)} WAV files...")
    pool_chunks = []
    pool_duration = 0.0
    MAX_POOL_SEC = 130 * 60  # need at most 130 min

    for wav_path in source_files:
        if pool_duration >= MAX_POOL_SEC:
            break
        try:
            audio, sr = sf.read(wav_path, dtype="float32")
            if len(audio.shape) > 1:
                audio = np.mean(audio, axis=1)
            if sr != 16000:
                try:
                    import librosa
                    audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)
                    sr = 16000
                except ImportError:
                    continue
            pool_chunks.append(audio)
            pool_duration += len(audio) / sr
        except Exception as e:
            log.warning(f"Skipping {wav_path}: {e}")

    if not pool_chunks:
        log.error("Could not load any source WAV files")
        return

    # Tile pool to be long enough
    pool = np.concatenate(pool_chunks)
    pool_sec = len(pool) / 16000
    log.info(f"Source pool: {pool_sec:.0f}s total")

    for target_min in DURATION_TARGETS_MINUTES:
        target_sec = target_min * 60
        out_path = os.path.join(duration_dir, f"{target_min}min.wav")

        if os.path.exists(out_path):
            existing_dur = sf.info(out_path).duration
            if abs(existing_dur - target_sec) < 10:
                log.info(f"  {target_min}min.wav already exists ({existing_dur:.0f}s), skipping")
                continue

        # Tile pool to required length
        if pool_sec < target_sec:
            repeats = int(target_sec / pool_sec) + 2
            tiled = np.tile(pool, repeats)
        else:
            tiled = pool

        samples_needed = int(target_sec * 16000)
        audio_out = tiled[:samples_needed]

        if noise_augment:
            log.info(f"  Applying noise augmentation (SNR={snr_db:.0f}dB + reverb)...")
            audio_out = _add_noise_augmentation(audio_out, 16000, snr_db=snr_db)

        sf.write(out_path, audio_out, 16000)
        tiled_flag = "tiled+noise_augmented" if noise_augment and pool_sec < target_sec else (
            "tiled" if pool_sec < target_sec else "trimmed"
        )
        log.info(f"  Generated: {out_path} ({target_min} min, source={tiled_flag})")
        if pool_sec < target_sec:
            log.warning(
                f"  NOTE: {target_min}min.wav generated by tiling source audio "
                f"({pool_sec:.0f}s pool repeated). WER/SBER may be optimistic."
            )


# ---------------------------------------------------------------------------
# Format probe files (m4a and .ogg)
# ---------------------------------------------------------------------------

def generate_format_probes(output_dir: str):
    """Create a minimal m4a and .ogg probe file using ffmpeg."""
    import soundfile as sf
    import numpy as np

    # Find any WAV file to use as source
    import glob
    wav_files = glob.glob(os.path.join(output_dir, "**", "*.wav"), recursive=True)
    if not wav_files:
        log.warning("No WAV files found for format probe generation")
        return

    source = wav_files[0]
    log.info(f"Format probe source: {source}")

    # m4a
    m4a_path = os.path.join(output_dir, "_test_probe.m4a")
    if not os.path.exists(m4a_path):
        ret = subprocess.run(
            ["ffmpeg", "-y", "-i", source, "-t", "5", "-c:a", "aac", "-b:a", "128k", m4a_path],
            capture_output=True,
        )
        if ret.returncode == 0:
            log.info(f"  Created: {m4a_path}")
        else:
            log.warning(f"  Could not create m4a (ffmpeg not available or aac encoder missing): {ret.stderr.decode(errors='replace')[:200]}")

    # .ogg
    ogg_path = os.path.join(output_dir, "_test_probe.ogg")
    if not os.path.exists(ogg_path):
        ret = subprocess.run(
            ["ffmpeg", "-y", "-i", source, "-t", "5", "-c:a", "libvorbis", "-q:a", "4", ogg_path],
            capture_output=True,
        )
        if ret.returncode == 0:
            log.info(f"  Created: {ogg_path}")
        else:
            log.warning(f"  Could not create .ogg (libvorbis encoder may not be present): {ret.stderr.decode(errors='replace')[:200]}")


# ---------------------------------------------------------------------------
# Multi-speaker synthetic files (mix two mono speakers)
# ---------------------------------------------------------------------------

def generate_multi_speaker_files(output_dir: str):
    """
    Mix pairs of single-speaker files to create synthetic multi-speaker audio.
    Output: multi_speaker/en/ and multi_speaker/zh/
    """
    import soundfile as sf
    import numpy as np
    import glob

    for lang in ("en", "zh"):
        single_dir = os.path.join(output_dir, "single_speaker", lang)
        multi_dir = os.path.join(output_dir, "multi_speaker", lang)
        os.makedirs(multi_dir, exist_ok=True)

        existing = [f for f in os.listdir(multi_dir) if f.endswith(".wav")]
        if len(existing) >= 5:
            log.info(f"Multi-speaker {lang}: already has {len(existing)} files, skipping")
            continue

        wav_files = sorted(glob.glob(os.path.join(single_dir, "*.wav")))
        if len(wav_files) < 2:
            log.warning(f"Need at least 2 {lang} single-speaker files to create multi-speaker; found {len(wav_files)}")
            continue

        pairs = [(wav_files[i], wav_files[(i + 1) % len(wav_files)])
                 for i in range(min(5, len(wav_files)))]

        for i, (file_a, file_b) in enumerate(pairs):
            # Load both files
            audio_a, sr = sf.read(file_a, dtype="float32")
            audio_b, _ = sf.read(file_b, dtype="float32")

            # Match lengths by trimming to shorter
            min_len = min(len(audio_a), len(audio_b))
            audio_a = audio_a[:min_len]
            audio_b = audio_b[:min_len]

            # Mix at equal levels
            mixed = (audio_a + audio_b) * 0.5

            out_name = f"multi_{lang}_{i:02d}.wav"
            out_path = os.path.join(multi_dir, out_name)
            sf.write(out_path, mixed, sr)

            # Combined transcript (concatenate both references)
            txt_a = os.path.splitext(file_a)[0] + ".txt"
            txt_b = os.path.splitext(file_b)[0] + ".txt"
            combined_txt = ""
            if os.path.exists(txt_a):
                with open(txt_a) as f:
                    combined_txt += f.read().strip()
            if os.path.exists(txt_b):
                with open(txt_b) as f:
                    combined_txt += " " + f.read().strip()

            out_txt = os.path.join(multi_dir, f"multi_{lang}_{i:02d}.txt")
            with open(out_txt, "w", encoding="utf-8") as f:
                f.write(combined_txt.strip())

            log.info(f"  Created multi-speaker: {out_name}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _print_inference_time_estimate():
    """
    Estimated total inference time for phase0_spike.py --test all.
    Assumes RTF=0.5 (M1 Pro, Cohere Transcribe base) and 30s chunk size.
    Adjust RTF_ESTIMATE if your hardware differs.

    Per DA疑六: EN must provide this estimate before claiming 5-day timeline is feasible.
    """
    RTF_ESTIMATE = 0.5  # conservative for M1 Pro; M1 base may be 1.0-1.5x

    estimates = []
    # Test 1: 4 strategies × 60min file
    # 30s strategy: 120 chunks × 30s × RTF + 1 baseline (3600s × RTF)
    for strategy_name, chunk_sec, n_chunks in [
        ("30s_5s_overlap", 30, 120),
        ("60s_5s_overlap", 60, 60),
        ("120s_5s_overlap", 120, 30),
        ("vad_energy", 30, 120),  # approximate
    ]:
        chunk_total = n_chunks * chunk_sec * RTF_ESTIMATE
        baseline = 3600 * RTF_ESTIMATE
        total = chunk_total + baseline
        estimates.append(f"  Test 1 / {strategy_name}: {total/60:.0f} min ({n_chunks} chunks + baseline)")

    # Test 2: 5 duration files
    for dur_min in [5, 15, 30, 60, 120]:
        t = dur_min * 60 * RTF_ESTIMATE / 60
        estimates.append(f"  Test 2 / {dur_min}min file: {t:.0f} min")

    test1_total = sum(
        (n * s + 3600) * RTF_ESTIMATE / 60
        for _, s, n in [("", 30, 120), ("", 60, 60), ("", 120, 30), ("", 30, 120)]
    )
    test2_total = sum(m * 60 * RTF_ESTIMATE / 60 for m in [5, 15, 30, 60, 120])
    grand_total = test1_total + test2_total

    log.info("=== Estimated Inference Time (RTF=%.1f, M1 Pro) ===" % RTF_ESTIMATE)
    for e in estimates:
        log.info(e)
    log.info(f"  Test 1 subtotal: {test1_total:.0f} min")
    log.info(f"  Test 2 subtotal: {test2_total:.0f} min")
    log.info(f"  TOTAL (Test 1+2): {grand_total:.0f} min ({grand_total/60:.1f} hours)")
    log.info("  Use --quick flag in phase0_spike.py to run reduced set (30min file only, 2 strategies)")


def main():
    parser = argparse.ArgumentParser(description="Phase 0 — Prepare test audio")
    parser.add_argument("--output-dir", default="./test_audio", help="Root output directory")
    parser.add_argument("--no-librispeech", action="store_true", help="Skip LibriSpeech download")
    parser.add_argument("--no-aishell", action="store_true", help="Skip AISHELL download")
    parser.add_argument("--no-duration-files", action="store_true", help="Skip synthetic duration files")
    parser.add_argument("--no-multi-speaker", action="store_true", help="Skip multi-speaker generation")
    parser.add_argument("--estimate-time", action="store_true",
                        help="Print estimated total inference time and exit")
    args = parser.parse_args()

    if args.estimate_time:
        _print_inference_time_estimate()
        return

    output_dir = os.path.abspath(args.output_dir)
    os.makedirs(output_dir, exist_ok=True)
    log.info(f"Output directory: {output_dir}")

    if not args.no_librispeech:
        try:
            download_librispeech(output_dir)
        except Exception as e:
            log.error(f"LibriSpeech download failed: {e}")

    if not args.no_aishell:
        try:
            download_aishell(output_dir)
        except Exception as e:
            log.error(f"AISHELL download failed: {e}")

    if not args.no_multi_speaker:
        try:
            generate_multi_speaker_files(output_dir)
        except Exception as e:
            log.error(f"Multi-speaker generation failed: {e}")

    if not args.no_duration_files:
        try:
            # Use single_speaker dirs as source pool
            source_dir = os.path.join(output_dir, "single_speaker")
            generate_duration_files(output_dir, source_dir)
        except Exception as e:
            log.error(f"Duration file generation failed: {e}")

    try:
        generate_format_probes(output_dir)
    except Exception as e:
        log.error(f"Format probe generation failed: {e}")

    # Print manifest
    manifest = {
        "_meta": {
            "generated": __import__("time").strftime("%Y-%m-%dT%H:%M:%SZ", __import__("time").gmtime()),
            "warnings": [
                "duration/ files are synthetic (tiled source audio). "
                "WER/SBER metrics on these files may be optimistic — "
                "they do not represent real meeting audio.",
                "noise_augment applied at SNR 15-20dB + short reverb. "
                "Not a substitute for AMI Corpus or real meeting recordings.",
            ],
        }
    }
    for root, dirs, files in os.walk(output_dir):
        for fname in files:
            if fname.startswith("_librispeech") or fname.startswith("_aishell"):
                continue  # skip archive files
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, output_dir)
            manifest[rel] = os.path.getsize(fpath)

    manifest_path = os.path.join(output_dir, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    log.info(f"Manifest written: {manifest_path}")
    log.info(f"Total files: {len(manifest) - 1}")  # -1 for _meta


if __name__ == "__main__":
    main()
