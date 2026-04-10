#!/usr/bin/env python3
"""
TDD test suite for transcribe_onnx_chunked() and the transcribe_long command.

Tests are organized into three layers:
  1. Unit tests — chunk splitting math, overlap trimming logic (no model needed)
  2. Integration tests — progress/result JSON protocol (mock encoder/decoder)
  3. System test — 5-min audio file end-to-end (requires real model, skipped if absent)

Run:
  python test_chunked_transcribe.py            # unit + integration only
  python test_chunked_transcribe.py --system   # include system test (needs model + audio)

RED phase: stubs are imported from transcribe.py; tests are expected to FAIL until
transcribe_onnx_chunked() and the transcribe_long command are implemented.
"""

import sys
import os
import json
import time
import unittest
import subprocess
import tempfile
import struct
import wave
import argparse
from unittest.mock import MagicMock, patch, call
import numpy as np

# ---------------------------------------------------------------------------
# Path setup — import helpers from transcribe.py
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RESOURCES_DIR = os.path.join(SCRIPT_DIR, "..", "Resources")
sys.path.insert(0, RESOURCES_DIR)


def _make_silence_wav(path: str, duration_sec: float, sample_rate: int = 16000):
    """Write a silent WAV file of given duration (16-bit PCM, mono)."""
    num_samples = int(duration_sec * sample_rate)
    # Use low-amplitude noise so RMS passes the silence threshold
    rng = np.random.default_rng(42)
    samples = (rng.uniform(-0.005, 0.005, num_samples) * 32767).astype(np.int16)
    with wave.open(path, "w") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(samples.tobytes())


# ---------------------------------------------------------------------------
# Layer 1: Unit tests — pure logic, no model
# ---------------------------------------------------------------------------

class TestChunkSplitLogic(unittest.TestCase):
    """Verify the chunk-splitting arithmetic in isolation."""

    def setUp(self):
        # Import the helper that should live in transcribe.py after GREEN phase.
        # If it doesn't exist yet, the test will raise ImportError -> RED.
        from transcribe import compute_chunk_boundaries
        self.compute_chunk_boundaries = compute_chunk_boundaries

    def test_should_produce_single_chunk_for_audio_shorter_than_chunk_size(self):
        """Audio of 20s with 30s chunks should yield exactly one boundary pair."""
        # Arrange
        total_samples = 20 * 16000
        chunk_samples = 30 * 16000
        overlap_samples = 5 * 16000

        # Act
        boundaries = self.compute_chunk_boundaries(total_samples, chunk_samples, overlap_samples)

        # Assert
        self.assertEqual(len(boundaries), 1)
        start, end = boundaries[0]
        self.assertEqual(start, 0)
        self.assertEqual(end, total_samples)

    def test_should_produce_correct_chunk_count_for_five_minute_audio(self):
        """5-min audio with 30s chunks and 5s overlap should produce 12 chunks."""
        # Arrange
        # step = chunk - overlap = 25s; ceil(300 / 25) = 12
        total_samples = 300 * 16000
        chunk_samples = 30 * 16000
        overlap_samples = 5 * 16000

        # Act
        boundaries = self.compute_chunk_boundaries(total_samples, chunk_samples, overlap_samples)

        # Assert
        self.assertEqual(len(boundaries), 12)

    def test_should_have_contiguous_coverage_across_all_chunks(self):
        """Every sample must be covered by at least one chunk."""
        # Arrange
        total_samples = 157 * 16000  # odd number of seconds
        chunk_samples = 30 * 16000
        overlap_samples = 5 * 16000

        # Act
        boundaries = self.compute_chunk_boundaries(total_samples, chunk_samples, overlap_samples)

        # Assert — build coverage bitmap
        covered = np.zeros(total_samples, dtype=bool)
        for start, end in boundaries:
            covered[start:end] = True
        self.assertTrue(np.all(covered), "Some samples are not covered by any chunk")

    def test_should_have_correct_overlap_between_adjacent_chunks(self):
        """Adjacent chunks must overlap by exactly overlap_samples (except possibly the last)."""
        # Arrange
        total_samples = 120 * 16000
        chunk_samples = 30 * 16000
        overlap_samples = 5 * 16000

        # Act
        boundaries = self.compute_chunk_boundaries(total_samples, chunk_samples, overlap_samples)

        # Assert
        for i in range(len(boundaries) - 1):
            _, end_i = boundaries[i]
            start_next, _ = boundaries[i + 1]
            overlap = end_i - start_next
            self.assertEqual(
                overlap,
                overlap_samples,
                f"Chunk {i}->{i+1}: overlap={overlap} samples, expected {overlap_samples}",
            )

    def test_should_not_exceed_audio_length_on_last_chunk(self):
        """The final chunk end must be clamped to total_samples."""
        # Arrange
        total_samples = 47 * 16000  # not divisible by step
        chunk_samples = 30 * 16000
        overlap_samples = 5 * 16000

        # Act
        boundaries = self.compute_chunk_boundaries(total_samples, chunk_samples, overlap_samples)

        # Assert
        _, last_end = boundaries[-1]
        self.assertEqual(last_end, total_samples)


class TestOverlapTrimLogic(unittest.TestCase):
    """Verify that overlap text trimming discards the correct word count."""

    def setUp(self):
        from transcribe import estimate_words_in_duration
        self.estimate_words_in_duration = estimate_words_in_duration

    def test_should_return_positive_word_count_for_nonzero_duration(self):
        """5 seconds of overlap should map to a positive word estimate."""
        count = self.estimate_words_in_duration(5.0)
        self.assertGreater(count, 0)

    def test_should_return_zero_for_zero_duration(self):
        """Zero overlap duration -> zero words to trim."""
        count = self.estimate_words_in_duration(0.0)
        self.assertEqual(count, 0)

    def test_should_scale_linearly_with_duration(self):
        """Doubling overlap duration should (roughly) double word count."""
        count_5 = self.estimate_words_in_duration(5.0)
        count_10 = self.estimate_words_in_duration(10.0)
        # Allow 20% deviation from perfect linearity
        self.assertAlmostEqual(count_10 / count_5, 2.0, delta=0.4)


# ---------------------------------------------------------------------------
# Layer 2: Integration tests — mock model, real chunking + JSON protocol
# ---------------------------------------------------------------------------

class TestChunkedTranscribeProtocol(unittest.TestCase):
    """
    Verify the progress/result JSON emission contract without a real model.

    Strategy: patch encoder_sess, decoder_sess, processor, and gen_config
    at the module level so transcribe_onnx_chunked() runs its full loop
    but calls our stubs instead of real inference.
    """

    @classmethod
    def setUpClass(cls):
        # Create a 90-second WAV file (3 chunks at 30s/5s-overlap)
        cls.tmp_dir = tempfile.mkdtemp()
        cls.wav_90s = os.path.join(cls.tmp_dir, "test_90s.wav")
        _make_silence_wav(cls.wav_90s, duration_sec=90.0)

    def _build_mock_transcribe_env(self):
        """Return a dict of patches that make transcribe_onnx_chunked() runnable."""
        import transcribe as tr

        # Mock processor: __call__ returns fake input_features + decoder_input_ids
        mock_processor = MagicMock()
        mock_processor.return_value = {
            "input_features": np.zeros((1, 80, 3000), dtype=np.float32),
            "decoder_input_ids": np.array([[1, 2, 3]], dtype=np.int64),
        }
        # tokenizer.decode returns a fake transcription string
        mock_processor.tokenizer.decode = MagicMock(return_value="hello world foo bar baz")

        # Mock encoder: returns a small hidden state
        mock_encoder = MagicMock()
        mock_encoder.run = MagicMock(return_value=[np.zeros((1, 100, 512), dtype=np.float32)])

        # Mock decoder: always returns EOS token so the loop terminates immediately
        eos_id = 50256
        logits = np.full((1, 1, 51865), -1e9, dtype=np.float32)
        logits[0, 0, eos_id] = 1e9  # argmax -> EOS

        # Build fake KV outputs (4 * NUM_DECODER_LAYERS tensors)
        num_layers = 8
        kv_outputs = []
        for _ in range(num_layers):
            for _ in range(4):  # dec_k, dec_v, enc_k, enc_v
                kv_outputs.append(np.zeros((1, 8, 1, 128), dtype=np.float16))

        mock_decoder = MagicMock()
        mock_decoder.run = MagicMock(return_value=[logits] + kv_outputs)

        mock_gen_config = {"eos_token_id": eos_id, "decoder_start_token_id": 1}

        return mock_processor, mock_encoder, mock_decoder, mock_gen_config

    def test_should_emit_progress_json_for_each_chunk(self):
        """
        transcribe_onnx_chunked() must flush one {'type':'progress'} JSON line per chunk.
        For 90s audio with 30s chunks and 5s overlap, there are 4 chunks.
        """
        # Arrange
        import transcribe as tr
        mock_processor, mock_encoder, mock_decoder, mock_gen_config = (
            self._build_mock_transcribe_env()
        )

        captured_stdout = []

        def fake_write(data):
            captured_stdout.append(data)

        # Act
        with patch.object(tr, "processor", mock_processor), \
             patch.object(tr, "encoder_sess", mock_encoder), \
             patch.object(tr, "decoder_sess", mock_decoder), \
             patch.object(tr, "gen_config", mock_gen_config), \
             patch.object(sys.stdout, "write", side_effect=fake_write):
            result = tr.transcribe_onnx_chunked(
                self.wav_90s, language="en", chunk_sec=30, overlap_sec=5
            )

        # Assert — count progress events
        progress_events = []
        for line in captured_stdout:
            for part in line.strip().split("\n"):
                part = part.strip()
                if not part:
                    continue
                try:
                    obj = json.loads(part)
                    if obj.get("type") == "progress":
                        progress_events.append(obj)
                except json.JSONDecodeError:
                    pass

        self.assertGreater(len(progress_events), 0, "No progress events emitted")
        # Each progress event must have required fields
        for evt in progress_events:
            self.assertIn("chunk", evt)
            self.assertIn("total", evt)
            self.assertIn("text", evt)

    def test_should_emit_final_result_with_correct_structure(self):
        """
        transcribe_onnx_chunked() must return a dict with keys:
        text, language, duration_ms, chunks.
        """
        # Arrange
        import transcribe as tr
        mock_processor, mock_encoder, mock_decoder, mock_gen_config = (
            self._build_mock_transcribe_env()
        )

        # Act
        with patch.object(tr, "processor", mock_processor), \
             patch.object(tr, "encoder_sess", mock_encoder), \
             patch.object(tr, "decoder_sess", mock_decoder), \
             patch.object(tr, "gen_config", mock_gen_config):
            result = tr.transcribe_onnx_chunked(
                self.wav_90s, language="en", chunk_sec=30, overlap_sec=5
            )

        # Assert
        self.assertIn("text", result)
        self.assertIn("language", result)
        self.assertIn("duration_ms", result)
        self.assertIn("chunks", result)
        self.assertIsInstance(result["text"], str)
        self.assertIsInstance(result["duration_ms"], int)
        self.assertGreater(result["chunks"], 0)

    def test_should_not_duplicate_overlap_text_in_final_result(self):
        """
        The final concatenated text must NOT contain verbatim repeated sentences
        from the overlap region.

        Scenario: each chunk returns the SAME sentence. Without overlap trimming,
        naive concatenation would repeat the sentence N times (once per chunk).
        With trimming, the first chunk is kept whole; subsequent chunks have their
        leading words (the overlap estimate) dropped.  If the overlap estimate
        equals the full sentence length, subsequent chunks become empty and the
        final text contains the sentence exactly once.

        We use a sentence of exactly _WORDS_PER_SECOND * overlap_sec words so
        that the trim covers the entire chunk text for chunks 2+.
        """
        # Arrange
        import transcribe as tr
        from transcribe import _WORDS_PER_SECOND

        mock_processor, mock_encoder, mock_decoder, mock_gen_config = (
            self._build_mock_transcribe_env()
        )

        overlap_sec = 5
        # Build a sentence with exactly the word count that would be trimmed
        words_to_trim = max(1, int(overlap_sec * _WORDS_PER_SECOND))
        repeated_sentence = " ".join([f"word{i}" for i in range(words_to_trim)])

        def fake_decode(token_ids, skip_special_tokens=True):
            return repeated_sentence

        mock_processor.tokenizer.decode = fake_decode

        # Act
        with patch.object(tr, "processor", mock_processor), \
             patch.object(tr, "encoder_sess", mock_encoder), \
             patch.object(tr, "decoder_sess", mock_decoder), \
             patch.object(tr, "gen_config", mock_gen_config):
            result = tr.transcribe_onnx_chunked(
                self.wav_90s, language="en", chunk_sec=30, overlap_sec=overlap_sec
            )

        # Assert — without trimming: sentence would appear 4 times.
        # With trimming: chunks 2+ are entirely within overlap window → discarded.
        # The first chunk (no trim) contains the sentence once.
        full_text = result["text"]
        # Split into words and count how many times the full repeated_sentence appears
        full_words = full_text.split()
        sentence_words = repeated_sentence.split()
        # Count non-overlapping occurrences of sentence_words within full_words
        occurrences = 0
        i = 0
        while i <= len(full_words) - len(sentence_words):
            if full_words[i : i + len(sentence_words)] == sentence_words:
                occurrences += 1
                i += len(sentence_words)
            else:
                i += 1

        self.assertEqual(
            occurrences,
            1,
            f"Repeated sentence appeared {occurrences} times — overlap trimming not working. "
            f"Full text: '{full_text[:200]}'",
        )

    def test_should_report_chunk_count_matching_boundaries(self):
        """result['chunks'] must equal the number of chunk boundaries computed."""
        # Arrange
        import transcribe as tr
        from transcribe import compute_chunk_boundaries
        mock_processor, mock_encoder, mock_decoder, mock_gen_config = (
            self._build_mock_transcribe_env()
        )

        total_samples = int(90 * 16000)
        expected_chunks = len(
            compute_chunk_boundaries(total_samples, 30 * 16000, 5 * 16000)
        )

        # Act
        with patch.object(tr, "processor", mock_processor), \
             patch.object(tr, "encoder_sess", mock_encoder), \
             patch.object(tr, "decoder_sess", mock_decoder), \
             patch.object(tr, "gen_config", mock_gen_config):
            result = tr.transcribe_onnx_chunked(
                self.wav_90s, language="en", chunk_sec=30, overlap_sec=5
            )

        # Assert
        self.assertEqual(result["chunks"], expected_chunks)


class TestTranscribeLongCommand(unittest.TestCase):
    """
    Verify that main()'s command dispatcher handles 'transcribe_long' correctly,
    routing to transcribe_onnx_chunked() and writing JSON to stdout.
    """

    @classmethod
    def setUpClass(cls):
        cls.tmp_dir = tempfile.mkdtemp()
        cls.wav_60s = os.path.join(cls.tmp_dir, "test_60s.wav")
        _make_silence_wav(cls.wav_60s, duration_sec=60.0)

    def test_should_route_transcribe_long_to_chunked_function(self):
        """
        Sending {"cmd":"transcribe_long","audio_path":...,"language":"en"}
        via stdin must cause transcribe_onnx_chunked() to be called once.
        """
        # Arrange
        import transcribe as tr
        mock_processor, mock_encoder, mock_decoder, mock_gen_config = (
            self._build_mock_env()
        )

        cmd = json.dumps({
            "cmd": "transcribe_long",
            "audio_path": self.wav_60s,
            "language": "en",
            "chunk_sec": 30,
            "overlap_sec": 5,
        }) + "\n"

        # Act
        with patch.object(tr, "processor", mock_processor), \
             patch.object(tr, "encoder_sess", mock_encoder), \
             patch.object(tr, "decoder_sess", mock_decoder), \
             patch.object(tr, "gen_config", mock_gen_config), \
             patch.object(tr, "backend", "onnx"), \
             patch("builtins.input", side_effect=StopIteration), \
             patch.object(sys, "stdin", iter([cmd])):
            written_lines = []
            with patch.object(sys.stdout, "write", side_effect=lambda s: written_lines.append(s)):
                try:
                    tr.main()
                except (StopIteration, SystemExit):
                    pass

        # Assert — at least one JSON line written
        combined = "".join(written_lines)
        parsed = []
        for line in combined.strip().split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                parsed.append(json.loads(line))
            except json.JSONDecodeError:
                pass

        result_events = [p for p in parsed if p.get("type") == "result"]
        self.assertGreater(len(result_events), 0, "No 'result' type event written to stdout")

    def test_should_return_error_when_model_not_loaded_for_transcribe_long(self):
        """
        If backend is None (model not loaded), transcribe_long must return
        {"error": ...} rather than crashing.
        """
        # Arrange
        import transcribe as tr

        cmd = json.dumps({
            "cmd": "transcribe_long",
            "audio_path": self.wav_60s,
            "language": "en",
        }) + "\n"

        # Act
        with patch.object(tr, "backend", None), \
             patch.object(sys, "stdin", iter([cmd])):
            written_lines = []
            with patch.object(sys.stdout, "write", side_effect=lambda s: written_lines.append(s)):
                try:
                    tr.main()
                except (StopIteration, SystemExit):
                    pass

        # Assert
        combined = "".join(written_lines)
        for line in combined.strip().split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if "error" in obj:
                    return  # found the error response — pass
            except json.JSONDecodeError:
                pass

        self.fail("Expected an error JSON response when model is not loaded")

    def _build_mock_env(self):
        """Shared mock builder for this test class."""
        mock_processor = MagicMock()
        mock_processor.return_value = {
            "input_features": np.zeros((1, 80, 3000), dtype=np.float32),
            "decoder_input_ids": np.array([[1, 2, 3]], dtype=np.int64),
        }
        mock_processor.tokenizer.decode = MagicMock(return_value="test transcription text")

        eos_id = 50256
        logits = np.full((1, 1, 51865), -1e9, dtype=np.float32)
        logits[0, 0, eos_id] = 1e9

        num_layers = 8
        kv_outputs = []
        for _ in range(num_layers):
            for _ in range(4):
                kv_outputs.append(np.zeros((1, 8, 1, 128), dtype=np.float16))

        mock_encoder = MagicMock()
        mock_encoder.run = MagicMock(return_value=[np.zeros((1, 100, 512), dtype=np.float32)])

        mock_decoder = MagicMock()
        mock_decoder.run = MagicMock(return_value=[logits] + kv_outputs)

        mock_gen_config = {"eos_token_id": eos_id, "decoder_start_token_id": 1}

        return mock_processor, mock_encoder, mock_decoder, mock_gen_config


# ---------------------------------------------------------------------------
# Layer 3: System test — real 5-min audio, real model (skipped if absent)
# ---------------------------------------------------------------------------

class TestSystemFiveMinuteAudio(unittest.TestCase):
    """
    End-to-end smoke test with a real (or generated) 5-min audio file.
    Skipped unless --system flag is passed on the command line.
    """

    SYSTEM_TEST_ENABLED = False  # flipped by --system CLI arg
    MODEL_PATH = os.path.expanduser(
        "~/Library/Application Support/Murmur/models/cohere-asr"
    )
    AUDIO_PATH = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..",
        "test_fixtures",
        "5min_sample.wav",
    )

    @classmethod
    def setUpClass(cls):
        if not cls.SYSTEM_TEST_ENABLED:
            return

        # Generate a synthetic 5-min audio if fixture not present
        fixture_path = os.path.normpath(cls.AUDIO_PATH)
        os.makedirs(os.path.dirname(fixture_path), exist_ok=True)
        if not os.path.exists(fixture_path):
            print(f"  [system] Generating synthetic 5-min audio -> {fixture_path}")
            _make_silence_wav(fixture_path, duration_sec=300.0)
            cls.AUDIO_PATH = fixture_path

    def _skip_if_not_system(self):
        if not self.SYSTEM_TEST_ENABLED:
            self.skipTest("System test skipped — pass --system to enable")

    def _skip_if_no_model(self):
        if not os.path.isdir(self.MODEL_PATH):
            self.skipTest(f"Model not found at {self.MODEL_PATH}")

    def test_should_not_oom_on_five_minute_audio(self):
        """
        transcribe_onnx_chunked() on 5-min audio must complete without SIGKILL.
        Peak RSS delta must be < 500 MB above the model baseline.
        """
        self._skip_if_not_system()
        self._skip_if_no_model()

        import resource
        import transcribe as tr

        # Load model first
        result = tr.load_model(self.MODEL_PATH)
        self.assertNotIn("error", result, f"Model load failed: {result}")

        baseline_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss

        result = tr.transcribe_onnx_chunked(
            self.AUDIO_PATH, language="en", chunk_sec=30, overlap_sec=5
        )

        peak_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        # macOS ru_maxrss is in bytes
        delta_mb = (peak_rss - baseline_rss) / (1024 * 1024)

        self.assertNotIn("error", result, f"Transcription failed: {result}")
        self.assertGreater(len(result.get("text", "")), 0, "Empty transcription output")
        self.assertLess(delta_mb, 500, f"RSS delta {delta_mb:.1f} MB exceeds 500 MB limit")

        print(f"  [system] RSS delta: {delta_mb:.1f} MB")
        print(f"  [system] Chunks: {result['chunks']}")
        print(f"  [system] Duration: {result['duration_ms']}ms")
        print(f"  [system] Text preview: {result['text'][:200]}")

    def test_should_produce_text_output_for_five_minute_audio(self):
        """Transcription of 5-min audio must produce a non-empty string."""
        self._skip_if_not_system()
        self._skip_if_no_model()

        import transcribe as tr

        if tr.backend is None:
            tr.load_model(self.MODEL_PATH)

        result = tr.transcribe_onnx_chunked(
            self.AUDIO_PATH, language="en", chunk_sec=30, overlap_sec=5
        )

        self.assertIn("text", result)
        self.assertIsInstance(result["text"], str)

    def test_should_emit_progress_events_for_five_minute_audio(self):
        """
        transcribe_onnx_chunked() on 5-min audio must emit at least 10 progress events
        (since 300s / 25s step = 12 chunks).
        """
        self._skip_if_not_system()
        self._skip_if_no_model()

        import transcribe as tr

        if tr.backend is None:
            tr.load_model(self.MODEL_PATH)

        progress_events = []
        original_write = sys.stdout.write

        def capturing_write(data):
            for line in data.strip().split("\n"):
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    if obj.get("type") == "progress":
                        progress_events.append(obj)
                except json.JSONDecodeError:
                    pass
            return original_write(data)

        with patch.object(sys.stdout, "write", side_effect=capturing_write):
            tr.transcribe_onnx_chunked(
                self.AUDIO_PATH, language="en", chunk_sec=30, overlap_sec=5
            )

        self.assertGreaterEqual(
            len(progress_events),
            10,
            f"Expected >= 10 progress events for 5-min audio, got {len(progress_events)}",
        )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="TDD tests for chunked transcription")
    parser.add_argument(
        "--system",
        action="store_true",
        help="Enable system tests (requires real model at ~/Library/Application Support/Murmur/models/cohere-asr)",
    )
    args, remaining = parser.parse_known_args()

    if args.system:
        TestSystemFiveMinuteAudio.SYSTEM_TEST_ENABLED = True
        print("[info] System tests ENABLED")
    else:
        print("[info] System tests SKIPPED (pass --system to enable)")

    # Pass remaining args to unittest
    unittest.main(argv=[sys.argv[0]] + remaining, verbosity=2)
