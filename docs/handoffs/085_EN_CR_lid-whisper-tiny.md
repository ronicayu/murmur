---
from: EN
to: CR
pri: P2
status: WIP
created: 2026-04-25
branch: feat/lid-whisper-tiny
refs: 080
---

## ctx

Audio-based language identification (LID). Today's auto-detect uses the
active macOS input method, which is wrong for users who type in one
language and dictate in another. This handoff captures progress on a
Whisper-tiny ONNX LID path that runs locally on the recorded audio
before the Cohere transcriber is invoked.

Not yet ready for review — opening this handoff so the work is
checkpointed and the team can see scope.

## what was added

### Service (`Murmur/Services/LanguageIdentificationService.swift`)

- `LIDResult { code: String, confidence: Float }` and
  `LanguageIdentifying` protocol (actor-friendly, async).
- `WhisperLanguageTokens` — the 99-language code table and the
  `<|LANG|>` token-ID range derived from openai/whisper's tokenizer
  (first ID 50259, contiguous block).
- `CohereLanguageMapping` — gates Whisper's 99 languages to Cohere's
  supported 14 (en, zh, ja, ko, fr, de, es, pt, it, nl, pl, el, ar, vi).
  Returns nil for anything outside that set so the caller can fall
  through to the existing manual / IME-based language.
- `LanguageIdentificationService` actor:
  - Loads quantised Whisper-tiny encoder + decoder via
    `OnnxRuntimeBindings`. 2 intra-op threads, full graph optimisation.
  - `identify(audioURL:)` loads a 5-second probe (16 kHz mono fp32, via
    `AVAudioConverter` if the source needs resampling), runs the encoder,
    then a single decoder step seeded with `<|startoftranscript|>`. The
    next-token logits at position 0 carry the language distribution.
  - Softmaxes only over the language-token block (not the full vocab) for
    a meaningful confidence score.
  - Handles fp32 and fp16 logits (vImage-based fp16→fp32 conversion).
- `WhisperMelExtractor` — bespoke 80-mel log-spectrogram extractor for
  Whisper's exact knobs (n_fft 400, hop 160, HTK mel scale, log10 +
  clip-to-max-minus-8 + (x+4)/4 normalisation, padded to 3000 frames).
  Intentionally separate from `MelSpectrogramExtractor` because every
  knob differs from Cohere ASR.

### ModelManager (`Murmur/Services/ModelManager.swift`)

- New `AuxiliaryModel` enum, parallel to `ModelBackend` but with no
  notion of "active" — each aux model is downloaded/managed
  independently on demand.
- `lidWhisperTiny` case: `onnx-community/whisper-tiny`, ~40 MB,
  allow-patterns scoped to `encoder_model_quantized.onnx`,
  `decoder_model_quantized.onnx`, and `*.json`. Required-files check
  matches the allow set.
- ModelManager gains `auxiliaryStates` published dict and
  `auxiliaryModelPath(_:)` lookup. (Download/install path implementation
  details follow the existing primary-model code path.)

### Coordinator (`Murmur/AppCoordinator.swift`)

- New optional `lid: (any LanguageIdentifying)?` slot. Nil = LID disabled.
- `resolveTranscriptionLanguageAsync(audioURL:)` async resolver used by
  the non-streaming path:
  - If `autoDetectLanguage` UserDefault is off → returns the existing
    sync `resolveTranscriptionLanguage()` result.
  - If on but no LID service → logs warning, surfaces error pill
    ("Language model not installed"), falls back.
  - Otherwise runs `lid.identify`, logs detected/confidence/mapped/
    threshold/fallback, and trusts the detected code IFF
    `confidence >= 0.60` AND it maps to a Cohere-supported language.
- LID confidence threshold: `0.60`, marked tunable from real-world
  `.public` LID logs.
- LID failure is **never fatal** to transcription — every error path
  falls through to the existing language resolver.
- Streaming V3 deliberately does **not** call this — pre-roll LID would
  add latency to first-partial. Documented in code comment.

### App wiring (`Murmur/MurmurApp.swift`)

- On launch, if the LID aux model is already on disk, instantiate
  `LanguageIdentificationService` and assign to `coord.lid`.
- Subscribes to `modelManager.$auxiliaryStates` so the LID service is
  attached/detached live as the aux model is downloaded or removed.

### Settings (`Murmur/Views/SettingsView.swift`)

- New section for the LID auxiliary model: download / state / size, plus
  the `autoDetectLanguage` toggle. Toggle is disabled until the model is
  installed.

### Tests (`Murmur/Tests/LanguageIdentificationTests.swift`)

- `MockLanguageIdentifier` test double (canned success/failure).
- `CohereLanguageMappingTests` — supported maps to self, unsupported
  (Thai, Russian, garbage) maps to nil.
- `WhisperLanguageTokenTests` — first token is English, contiguous
  block sanity, code↔index round-trip.
- 232 lines total. No live ONNX model exercised in unit tests — that
  belongs in an integration suite (see open questions).

## status

- WIP. Code compiles and unit tests pass locally.
- No real-audio integration test yet (no committed fixture for the
  Whisper mel extractor or end-to-end identify path).
- LID confidence threshold (0.60) is a starting guess — needs tuning
  from real `.public` log lines once the feature is dogfooded.
- Float16 logits decode path is implemented but not exercised — current
  quantised whisper-tiny export emits fp32 logits.
- No streaming V3 LID — explicitly out of scope this round.

## open questions for CR

1. Is the AuxiliaryModel parallel hierarchy the right shape, or should
   LID be a sub-state of the primary `ModelBackend` enum?
2. Confidence threshold lives on `AppCoordinator` as a private static.
   Move to a tunable user default? Surface in Settings (advanced)?
3. The pill error "Language detection unavailable" surfaces user-facing
   text on every LID inference failure. Too noisy? Silent + log only?
4. `WhisperMelExtractor` is 240 lines of DSP with no integration test
   against a librosa reference. Acceptable to ship without one, or block
   until QA writes a fixture-based comparison?

## refs

- Service: `Murmur/Services/LanguageIdentificationService.swift`
- Model wiring: `Murmur/Services/ModelManager.swift` (`AuxiliaryModel`
  enum and surrounding plumbing)
- Coordinator: `Murmur/AppCoordinator.swift`
  (`resolveTranscriptionLanguageAsync`)
- App: `Murmur/MurmurApp.swift` (live attach/detach)
- Settings UI: `Murmur/Views/SettingsView.swift`
- Tests: `Murmur/Tests/LanguageIdentificationTests.swift`

## out

(CR fills in.)
