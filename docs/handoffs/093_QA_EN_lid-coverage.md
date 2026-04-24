---
from: QA
to: EN
pri: P1
status: CHG:4
created: 2026-04-25
branch: feat/lid-whisper-tiny
refs: 091
---

## ctx

Coverage audit of the Whisper-tiny LID feature from handoff 091. Read
`LanguageIdentificationService.swift`, `AppCoordinator.swift`
(`resolveTranscriptionLanguageAsync`), `ModelManager.swift`
(`AuxiliaryModel` + surrounding plumbing), and the existing 232-line test
file. Compared against the primary-model test suite (ManifestVerificationTests,
DownloadCancelIntegrationTests, DownloadStallTimeoutTests) to spot where the
auxiliary path diverges in coverage.

## current coverage

**`CohereLanguageMappingTests`** (3 assertions)
- Supported codes map to themselves (en, zh, vi).
- Unsupported (th, ru, garbage) map to nil.
- Missing: all 14 supported codes enumerated; edge cases around codes with
  regional suffixes (e.g. "zh-Hant").

**`WhisperLanguageTokenTests`** (4 tests)
- First token is English (ID 50259), second is Chinese.
- All 14 Cohere-supported codes are present in Whisper's language table.
- Out-of-range token IDs return nil (below first, well above last).
- Missing: last valid ID (`lastID`) returns non-nil; ID exactly one past
  `lastID` returns nil (boundary).

**`ResolveTranscriptionLanguageAsyncTests`** (7 tests, @MainActor)
- autoDetect off → sync fallback called, LID not invoked (callCount == 0). ✓
- autoDetect on, lid == nil → fallback to picker value. ✓
- autoDetect on, high-confidence supported code → overrides picker. ✓
- autoDetect on, low-confidence (0.30) → fallback. ✓
- autoDetect on, exactly threshold (0.60) → trusts detection. ✓
- autoDetect on, high-confidence unsupported (Thai) → fallback. ✓
- autoDetect on, inference throws → fallback. ✓
- autoDetect on, picker == "auto" + below-threshold → non-empty 2-letter code. ✓
- Missing: lid == nil branch does NOT assert the pill toast side-effect.
- Missing: inference-throws branch does NOT assert the pill toast side-effect.
- Missing: no test for the `mapped != nil` but `confidence < 0.60` combined
  path (distinct from low-confidence returning fallback — already covered, but
  the "map returns non-nil, confidence just below threshold" combination is not
  explicitly named).

**`AuxiliaryModelStateTests`** (3 tests)
- Default (no manifest) → `.notDownloaded`. ✓
- In-flight `.downloading` and `.verifying` → `isAuxiliaryDownloaded` false. ✓
- `lidWhisperTiny` metadata: subdirectory, requiredFiles non-empty,
  allowPatterns contain "encoder_model". ✓
- Missing: `auxiliaryManifestIsValid` with a well-formed manifest on disk
  (the "truthy" path is never exercised with a synthetic manifest).
- Missing: `deleteAuxiliary` clears state and removes directory.
- Missing: `refreshAuxiliaryState` transitions: no-manifest → `.notDownloaded`;
  valid-manifest → `.ready`.
- Missing: `downloadAuxiliary` guard — already-downloading returns without
  starting a second subprocess (primary-model equivalent tested in
  DownloadCancelIntegrationTests but absent for auxiliary).
- Missing: `auxiliaryModelPath` returns nil when manifest invalid, non-nil
  when valid.

**DSP / inference internals — zero coverage**
- `WhisperMelExtractor`: no tests for `logAndNormalise`, `reflectPad`,
  `padOrTruncate`, output tensor shape, or filterbank row sums.
- `argmaxOverLanguages` / `readLastLogitRow`: private actor methods; not
  directly testable without ONNX. fp16 conversion path (`float16ToFloat32`)
  has no exercisable seam.
- `loadProbeSamples`: no test for the native-16kHz fast path vs. the
  AVAudioConverter resampling path.

## gaps

### P0 — block merge

**P0-1: `auxiliaryManifestIsValid` happy-path not covered.**
`isAuxiliaryDownloaded` delegates to `auxiliaryManifestIsValid`, which returns
true only when a manifest exists and every file's size matches. The existing
`testDefaultsToNotDownloaded` test only confirms the false path. If the
size-check logic has a bug (off-by-one, wrong attribute key), no test catches
it before the UI wrongly marks the model as not installed — or worse, wrongly
marks it as ready.

**P0-2: `auxiliaryModelPath` nil/non-nil not tested.**
`MurmurApp` calls `auxiliaryModelPath(.lidWhisperTiny)` on launch to decide
whether to instantiate `LanguageIdentificationService`. Zero coverage means a
regression here would silently wire up a nil LID service even when the model is
on disk (or vice versa).

**P0-3: `deleteAuxiliary` state reset not tested.**
After deletion, `coord.lid` must be set to nil by the `onReceive` subscriber in
`MurmurApp`. The subscriber reads `auxiliaryState`, which reads `auxiliaryStates`
dict. If `deleteAuxiliary` fails to write `.notDownloaded` back, the LID service
remains wired to a now-missing model directory and every subsequent inference
throws. No test covers this flow.

**P0-4: `refreshAuxiliaryState` transitions not tested.**
Called at app launch. If the manifest-on-disk check produces the wrong result,
the LID toggle in Settings renders the wrong state on every cold boot. The
primary-model equivalent (`refreshState`) is exercised indirectly through
ManifestVerificationTests; the auxiliary path has nothing.

### P1 — should add before GA

**P1-1: Pill toast side-effects in `resolveTranscriptionLanguageAsync`.**
The `lid == nil` branch and the `catch` branch both call
`pill.show(state: .error(...))`. Currently not asserted. A future refactor
could silently remove the user-facing toast. Testable today by injecting a
`MockPill` (or spy-wrapping the existing `FloatingPillController`) in
`ResolveTranscriptionLanguageAsyncTests`.

**P1-2: `logAndNormalise` correctness.**
`logAndNormalise` is a `static` method on `WhisperMelExtractor` and is directly
callable without ONNX or AVFoundation. It implements Whisper's three-step
normalisation (log10 clip, floor at max − 8, (x + 4) / 4). A bug here
(wrong constant, wrong order of operations) would silently shift every mel
frame and degrade LID accuracy — the model would still run, just poorly. This
is the highest-leverage pure-Swift DSP test that can be added with no ONNX
dependency.

**P1-3: `reflectPad` boundary values.**
`reflectPad` is a standalone private method. It is the only non-trivial
indexing logic in `WhisperMelExtractor` and the most likely home for an
off-by-one. At padSize == 0 it must return the input unchanged; at padSize ==
n − 1 (maximum safe reflection) it must not access out-of-bounds indices.
Testable by making it `internal` or extracting it as a package-level function
(a one-line change).

**P1-4: `auxiliaryManifestIsValid` size-mismatch returns false.**
Companion to P0-1. Write a manifest with a correct filename but a wrong size
entry; assert false. Symmetric with
`test_manifestIsValid_falseWhenFileTruncated` in ManifestVerificationTests.

### P2 — defer / dogfood first

**P2-1: fp16 logit decode path.**
`readLastLogitRow` has a `case .float16` branch that calls `float16ToFloat32`.
The current quantised whisper-tiny export emits fp32, so this branch is
unreachable in the field. Testing requires either a synthetic `ORTValue` or
a fixture fp16 blob. Defer until the export format changes.

**P2-2: `loadProbeSamples` resampling path.**
AVAudioConverter branch requires a real audio file at a non-16 kHz sample rate.
Integration test territory. Defer with a dogfood note to capture a
non-16 kHz fixture once production logs are available.

**P2-3: End-to-end `identify` with a real fixture.**
Full mel → encoder → decoder → argmax path. Requires a committed audio
fixture and the 40 MB ONNX weights. Not feasible in CI without LFS. Defer
to an integration suite.

**P2-4: Confidence threshold tuning coverage.**
The 0.60 threshold is acknowledged as a first guess in 091. A parametric test
matrix (code × confidence at 0.59 / 0.60 / 0.61) already exists structurally
via `ResolveTranscriptionLanguageAsyncTests`; the exact-threshold test at line
147 anchors the boundary. Threshold-tuning feedback belongs in production logs,
not additional unit tests. No action until threshold moves.

**P2-5: `WhisperMelExtractor` vs. librosa reference.**
240-line DSP with no fixture comparison. The risk is non-trivial, but producing
a reference requires a Python environment + a known audio clip. Gate this on
the first report of a language being misidentified consistently in dogfooding.

## proposed new tests

All five are automatable without ONNX, AVFoundation fixtures, or live audio.
Listed in priority order.

---

**T1 — `auxiliaryManifestIsValid_returnsTrue_whenManifestAndSizesMatch`**
Class: `AuxiliaryModelStateTests`
Arrange: write a temp directory; write a fake `onnx/encoder_model_quantized.onnx`
(e.g. 8 bytes of zeros); write a `manifest.json` whose `files` entry for that
path records `size == 8`. Use `__testing_setAuxiliaryDirectory` to redirect.
Act: call `mm.auxiliaryManifestIsValid(.lidWhisperTiny)`.
Assert: returns true.
Rationale: closes P0-1 and the missing truthy half of `isAuxiliaryDownloaded`.

---

**T2 — `auxiliaryModelPath_returnsNil_whenManifestAbsent` /
`auxiliaryModelPath_returnsDirectory_whenManifestValid`**
Class: `AuxiliaryModelStateTests`
Two sub-cases in one test method or split. No-manifest case uses the existing
temp dir pattern. Valid-manifest case reuses the fixture from T1.
Assert path == nil (absent), path == temp dir (valid).
Rationale: closes P0-2. Directly exercises the `MurmurApp` launch gate.

---

**T3 — `deleteAuxiliary_clearStateAndDirectory`**
Class: `AuxiliaryModelStateTests`
Arrange: temp dir with a planted file + valid manifest + state == `.ready`.
Act: `mm.deleteAuxiliary(.lidWhisperTiny)`.
Assert: `auxiliaryState(for:) == .notDownloaded`;
`FileManager.default.fileExists(atPath: dir.path) == false`.
Rationale: closes P0-3. Validates the state reset that `MurmurApp`'s Combine
subscriber depends on for detaching `coord.lid`.

---

**T4 — `refreshAuxiliaryState_setsReady_whenValidManifest` /
`refreshAuxiliaryState_setsNotDownloaded_whenNoManifest`**
Class: `AuxiliaryModelStateTests`
Two assertions, same arrange pattern as T1/T2.
Rationale: closes P0-4. Mirrors `test_migration_setsStateReady_afterManifestGenerated`
from ManifestVerificationTests for the auxiliary path.

---

**T5 — `logAndNormalise_appliesWhisperNormalisation`**
Class: new `WhisperMelExtractorTests` (or append to existing LID file)
Arrange: a small known input, e.g. `[1e-10, 1.0, 100.0]` (one frame, three
fictitious mel bins). Compute expected output by hand:
  log10([1e-10, 1.0, 100.0]) = [−10.0, 0.0, 2.0];
  max = 2.0; floor = 2.0 − 8.0 = −6.0;
  after clamp: [−6.0, 0.0, 2.0];
  (x + 4) / 4: [−0.5, 1.0, 1.5].
Act: call `WhisperMelExtractor.logAndNormalise(input)` (requires making the
method `internal` — currently `private static`).
Assert: output matches expected within tolerance 1e-5.
Rationale: P1-2. Static pure-Swift function, no dependencies. Anchors the
normalisation constants so a future accidental edit (wrong divisor, wrong clip
delta) fails immediately.

Note on `reflectPad` (P1-3): extracting it for test requires making it
`internal`. This is a one-line access-modifier change. If EN is comfortable
with that, T5 could be extended to cover `reflectPad([], padSize: 0)` → `[]`
and a small known-input boundary case. Otherwise the test is omitted and the
risk accepted.

## out

**Verdict: CHG:4** — four P0 gaps (T1–T4) must be closed before merge.

Must-add list:
1. T1: `auxiliaryManifestIsValid` truthy path.
2. T2: `auxiliaryModelPath` nil / non-nil.
3. T3: `deleteAuxiliary` state + filesystem cleanup.
4. T4: `refreshAuxiliaryState` both branches.

T5 (`logAndNormalise`) is strongly recommended (P1-2) but not a merge blocker
given the feature is opt-in and LID failure is never fatal to transcription.

P0 justification: items T1–T4 are all model-lifecycle tests that map directly
to the `MurmurApp` launch and attach/detach logic. If any of these paths
regress silently, the LID toggle in Settings will show incorrect state or
`coord.lid` will be nil even when the model is on disk — making the entire
feature appear broken to users without any log signal pointing at the model
manager.
