# Design: FireRed Chinese ASR integration

**Status:** Draft (pending user review)
**Date:** 2026-04-25
**Branch:** TBD (proposed `feat/firered-backend`)

## Problem

Murmur's existing transcription backends (Cohere ONNX/HF, Whisper) underperform on Chinese audio compared to Xiaohongshu's FireRedASR2-AED (1.1B params, AED architecture). A spike on the SenseVoice `asr_example_cn_en.wav` Chinese-English mixed sample produced:

| Backend                       | CER vs ground truth | Notes |
|-------------------------------|--------------------:|-------|
| FireRedASR2-AED               | **8.94%**           | Character-faithful; preserves "做…做…做" repetition and English code-switching as-is |
| Murmur Cohere ONNX (zh prompt)| 22.76%              | Paraphrases + adds punctuation; substitutes words ("通通"→"通常", "基本功"→"基本功能") |
| Murmur Cohere ONNX (en prompt)| 102.44%             | Mistranslates entire utterance into English |

Spike artefacts: `~/work/firered-spike/RESULTS.md`, `~/work/firered-spike/swift-spike/` (Swift coexistence proof).

We want Chinese users to get FireRed-quality transcription, **without breaking the existing experience for English/multilingual users**, and **without forcing a 1.24 GB additional download on users who don't need it**.

## Scope

**In:**

- New `ModelBackend.fireRed` case (4th backend), selectable in Settings → Model alongside Standard/High Quality/Whisper
- New "Use FireRed for Chinese transcription" sub-toggle visible under Cohere backends (Standard + High Quality)
- Both entry points share the same on-disk FireRed model files
- sherpa-onnx Swift xcframework integration alongside the existing `onnxruntime-swift-package-manager` dependency (coexistence verified by spike)
- Download / manifest / verify / cancel flow reuses existing `ModelManager` infrastructure
- Language-aware routing: only `zh` audio is sent to FireRed; everything else stays on Cohere/Whisper

**Out:**

- FireRed in V3 streaming (sherpa-onnx FireRedASR2-AED has no streaming mode — V3 always uses Cohere)
- FireRed for languages other than `zh` and `en` (FireRed supports those two; everything else falls back to Cohere)
- FireRed auxiliary models from FireRedASR2S (VAD/LID/Punc) — separate models, separate spec if ever needed
- Replacing Cohere as the default backend
- Removing or deprecating Whisper / Cohere HF
- A/B quality instrumentation
- Per-language opt-in beyond zh (e.g. "also use FireRed for English")

## User-facing design

### Settings → Model section

```
Engine

◯ Standard (Recommended)         1.5 GB · Downloaded                  ✓
    ☐ Use FireRed for Chinese transcription   (1.24 GB additional)
      Routes Chinese audio to FireRed for better accuracy.
      Other languages stay on Cohere. V1 only.

◯ High Quality                   4 GB · Cohere HF
    ☐ Use FireRed for Chinese transcription   (1.24 GB additional)
      (same description)

◯ Whisper                        1.6 GB

◯ FireRed (Chinese-first)        1.24 GB
   Best Chinese accuracy, including dialects and Chinese-English
   code-switching. Other languages auto-fallback to Cohere ONNX
   (1.5 GB also required).
```

The toggle row appears **only** when Standard or High Quality is the active backend, indented under it. Whisper and FireRed do not show the toggle (FireRed already routes Chinese to itself; Whisper is a separate model family unrelated to Cohere).

### Toggle behavior

- Default OFF — no behavior change for existing users
- When user flips OFF → ON:
  - If FireRed model already on disk and verified → toggle commits immediately, persisted to UserDefaults
  - If FireRed model missing → trigger download flow (same UI as a backend download — progress bar, cancel button, stall timeout); toggle reads "Downloading…" with spinner; actual ON state only commits on successful verify
  - If user cancels mid-download → toggle reverts to OFF, partial files cleaned up, persisted state stays OFF
  - If download fails (network / disk / verify) → toggle reverts to OFF, NSAlert with `MurmurError.Severity.critical`
- When user flips ON → OFF:
  - Routing immediately stops sending Chinese to FireRed
  - **Model files are NOT deleted** (user may toggle back; consistent with backend-switch behavior, which also keeps the previous backend's files)
  - Disk-cleanup is a separate user action via "Delete model" button (same as existing backends)

### FireRed backend selection

Selecting `FireRed (Chinese-first)` requires **both** FireRed and Cohere ONNX models to be present:

- FireRed handles `zh` and `en` audio
- Cohere ONNX is the fallback for any other language and for V3 streaming

Download UI when user picks FireRed from a clean state:
- Sequential download: Cohere ONNX first (1.5 GB), then FireRed (1.24 GB)
- Combined "2.74 GB" total shown up front
- Cancel during either step rolls both back to "not selected"
- If Cohere ONNX is already downloaded (the common case — most users land here from a Cohere onboarding choice), only FireRed (1.24 GB) downloads

Onboarding (first-run flow) gets a small addition: FireRed shows up as the 4th option with the same "1.24 GB + 1.5 GB Cohere fallback" disclosure.

### V3 streaming (unchanged)

Regardless of backend or toggle:
- V3 streaming always uses Cohere ONNX. FireRed has no streaming mode.
- The toggle's description includes "V1 only" so users understand.
- If a user picks the FireRed backend and uses V3 streaming, V3 falls through to Cohere ONNX. The pill UI continues to show "Standard" language-badge behavior; no special "downgrade" indicator (the user has been informed once at backend selection).

## Architecture

### `ModelBackend.fireRed`

New enum case in `Murmur/Services/ModelManager.swift`:

```swift
case fireRed

var displayName: String { "FireRed (Chinese-first)" }
var shortName: String { "FireRed" }
var modelRepo: String { "csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26" }
var requiredDiskSpace: Int64 { 1_300_000_000 }     // ~1.24 GB rounded up
var modelSubdirectory: String { "Murmur/Models-FireRed" }
var requiredFiles: [String] { [
    "encoder.int8.onnx",
    "decoder.int8.onnx",
    "tokens.txt",
] }
var requiresHFLogin: Bool { false }
var sizeDescription: String { "~1.24 GB" }
var description: String {
    "Best Chinese accuracy, including dialects and Chinese-English code-switching. "
        + "Other languages fall back to Cohere ONNX (1.5 GB additional)."
}
var allowPatterns: [String]? { [
    "encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt", "*.json",
] }
```

Note: `allowPatterns` excludes `test_wavs/*.wav` (~2 MB), saving a small amount of bandwidth.

### `useFireRedForChinese` toggle state

- New UserDefaults key: `useFireRedForChinese` (Bool, default `false`)
- Owned by `ModelManager` — exposed as `@Published var useFireRedForChinese: Bool`
- Setter has the same gating as `setActiveBackend(_:)`:
  - Cannot flip ON while a download is active
  - Flipping ON when FireRed not downloaded triggers the download flow; commits only on successful verify
  - Flipping OFF is unconditional, fires `committedUseFireRedChange.send(false)` so subscribers (transcription router) re-evaluate

### `FireRedTranscriptionService`

New file: `Murmur/Services/FireRedTranscriptionService.swift`

```swift
actor FireRedTranscriptionService {
    private let recognizer: SherpaOnnxOfflineRecognizer

    init(modelDirectory: URL) throws { ... }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> String
}
```

- Wraps the vendored `SherpaOnnx.swift` `SherpaOnnxOfflineRecognizer`
- Holds the recognizer for the lifetime of the service (avoids ~1.5 s reload per request — measured in spike)
- Actor-isolated to serialize calls (the C session is not thread-safe)
- Postprocessing: `.lowercased()` to match the official `asr.py` behavior we observed in spike

### Transcription routing

Existing dispatcher (lives in `TranscriptionService` and/or `AppCoordinator`) gets a small router on top:

```swift
func backendForRequest(language: String, version: TranscriptionVersion) -> BackendChoice {
    let active = modelManager.activeBackend
    let useFR = modelManager.useFireRedForChinese

    // V3 streaming: always Cohere
    if version == .v3Streaming { return .cohereStreaming }

    // FireRed backend
    if active == .fireRed {
        if language == "zh" || language == "en" { return .firered }
        return .cohereONNX // fallback for ja/ko/fr/...
    }

    // Cohere backends + toggle
    if (active == .onnx || active == .huggingface) && useFR && language == "zh" {
        return .firered
    }

    return .existing(active) // unchanged
}
```

Tested via a pure-function `LanguageRoutingTests` suite — no I/O.

### Bundling sherpa-onnx

**Files added to repo:**

```
Murmur/vendor/sherpa-onnx.xcframework/
   Info.plist
   macos-arm64_x86_64/
     libsherpa-onnx.a              (~42 MB; Git LFS)
     Headers/
       module.modulemap            (added by us — 5 lines)
       sherpa-onnx/c-api/c-api.h
       sherpa-onnx/c-api/cxx-api.h  (unused but present)
Murmur/Services/Vendor/SherpaOnnx.swift   (vendored from upstream, ~2249 lines)
```

**`module.modulemap` content:**

```
module SherpaOnnxC {
    umbrella header "sherpa-onnx/c-api/c-api.h"
    export *
    link "sherpa-onnx"
}
```

**`SherpaOnnx.swift` modification:** add `import SherpaOnnxC` after `import Foundation`. No other changes — keep upstream alignment for easy version bumps.

**`Package.swift` additions:**

```swift
.binaryTarget(
    name: "SherpaOnnxC",
    path: "vendor/sherpa-onnx.xcframework"
),
```

In the `Murmur` executable target:

```swift
dependencies: [
    "HotKey",
    .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
    "SherpaOnnxC",
],
linkerSettings: [
    .linkedLibrary("c++"),
],
```

**Version pin and update process:**

- Pin sherpa-onnx to v1.12.40 (the spike-verified version)
- `vendor/SHERPA_ONNX_VERSION.txt` records version + URL of the binary
- Bumping requires: download new tar.bz2, extract, re-add `module.modulemap`, replace `SherpaOnnx.swift` from the matching tag, run regression tests

**Disk impact of repo:** +42 MB Git LFS object, +~2250 lines of vendored Swift, +~5000 lines of vendored C header. App binary: +30–35 MB approximate (sherpa-onnx static lib stripped).

### onnxruntime coexistence (verified)

The spike (`~/work/firered-spike/swift-spike/`) confirmed:

- `nm libsherpa-onnx.a` shows `_OrtGetApiBase` as `U` (undefined) — sherpa-onnx does not embed onnxruntime
- The binary links against the existing `onnxruntime-swift-package-manager` (1.20+) and the symbols resolve cleanly
- A single executable can call both `SherpaOnnxOfflineRecognizer` (FireRed) and `ORTSession` (Cohere) with no conflicts

This means we don't need to change Murmur's existing `onnxruntime` dependency; FireRed picks up the same runtime.

### Download / manifest / verify

Reuse existing `ModelManager` machinery as-is:

- `download(for: .fireRed)` calls the same HuggingFace CLI subprocess path
- Manifest (SHA-256 + size per file) generated after successful download
- `isModelDownloaded(for: .fireRed)` does the size-only hot-path check
- `verify(for: .fireRed)` re-hashes
- `cancelDownload(for: .fireRed)` does SIGTERM→SIGKILL escalation, partial-file cleanup
- 90 s stall timeout from FU-07 applies
- Disk-space check on backend switch and on toggle ON

For the FireRed-backend "needs Cohere fallback" case, the download flow does Cohere first, then FireRed, surfacing combined progress. Cancel at any point rolls everything back. Implementation: a small `CompositeDownload` wrapper around two sequential `download(for:)` calls, sharing the cancel signal.

### Error handling

| Condition                                  | Surface                                              |
|--------------------------------------------|------------------------------------------------------|
| FireRed model files missing at request time| `MurmurError.modelNotFound` (severity `.critical`); pill shows short message |
| sherpa-onnx recognizer init fails          | `MurmurError.transcriptionFailed("FireRed init: ...")`; routing falls back to Cohere this request only; logged once per session |
| FireRed inference throws                   | Log `os_log` `.coordinator` category; fall back to Cohere ONNX for **this** request; user sees pill briefly say "Used Cohere fallback" |
| Toggle ON download fails                   | `MurmurError.Severity.critical` NSAlert; toggle reverts to OFF |
| User selects FireRed backend, Cohere ONNX missing | Combined download flow auto-includes Cohere; cancel = neither activated |
| Disk full mid-download                     | Existing `MurmurError.diskFull` path; partial files cleaned up |

## Testing

### Unit tests (TDD bites)

- `FireRedTranscriptionServiceTests`: with the spike's known wav, assert text matches recorded reference. Skip if `~/Library/Application Support/Murmur/Models-FireRed/` not present (mirrors existing pattern in `Phase0SpikeTests` for ONNX).
- `LanguageRoutingTests`: pure function over `(activeBackend, useFireRedForChinese, language, version)` → `BackendChoice`. Cover all 16+ branches.
- `ModelBackendFireRedTests`: enum properties (repo, files, disk space, manifest path, download patterns).
- `ModelManagerFireRedToggleTests`: setter rules — refused during download, persists to UserDefaults, fires `committedUseFireRedChange`.

### Integration tests

- Toggle ON without model → triggers download flow; toggle reads "Downloading"; eventual ON.
- Cancel during FireRed download → state reverts; partial files removed; second attempt succeeds.
- Backend switch Cohere → FireRed when Cohere already on disk → only FireRed downloads.
- Backend switch from clean state → FireRed → both Cohere ONNX and FireRed download sequentially.
- V3 streaming with toggle ON → still uses Cohere (no FireRed import attempted).

### Manual / UAT (post-implementation)

Per the team protocol's UT step. Scenarios:
1. Existing Cohere user enables toggle, says "你好 测试一下" → routed to FireRed, output matches spike characteristic style
2. Existing Cohere user enables toggle, says "Hello world" → routed to Cohere, English unchanged
3. New user picks FireRed in onboarding → both Cohere + FireRed download; first Chinese utterance uses FireRed; first Japanese utterance uses Cohere (logged as fallback)
4. Cancel mid-FireRed download → state restored, toggle OFF, files removed
5. Disk filling up halfway through FireRed download → critical alert; partial cleanup confirmed via Finder

### Regression

- All existing tests pass: `Phase0SpikeTests`, `ModelSwitchingTests`, `B3B4FixTests`, `LanguageBadgeTests`, `PunctuationCleanupTests`, `TranscriptionCorrectionTests`, V3 AX selection tests.
- Cohere ONNX session loads alongside sherpa-onnx in the same process (already verified by spike, but assert in CI by linking both at unit-test time).

## Risks & mitigations

| Risk                                                      | Mitigation                                                                    |
|-----------------------------------------------------------|-------------------------------------------------------------------------------|
| sherpa-onnx ABI changes in future versions                | Pin v1.12.40; document update procedure; regression tests gate version bumps |
| 42 MB binary in repo (Git LFS)                            | Acceptable — comparable to other ML xcframework distributions; `.gitattributes` track |
| User adds 1.24 GB to disk usage on toggle                 | Clear UI labelling ("1.24 GB additional"); user opts in; cancel works         |
| FireRed RTF 0.43 vs Cohere RTF 0.18 (2.4× slower)         | Still 2× faster than realtime; users opt in for quality; document in release notes |
| Mistaken zh/en routing on Chinese-English mixed audio when IME=en | Existing IME/LID resolver decides language. If misclassified, FireRed not invoked — no regression. Future improvement (out of scope): treat mixed audio as zh-route always |
| sherpa-onnx fails to init on Intel Mac                    | xcframework `Info.plist` declares `arm64,x86_64`; spike build was on arm64 — add Intel Mac smoke test before tagging release |

## Open questions / deferred decisions

- **Should Whisper backend also offer the toggle?** Spec says no (Whisper is multilingual SOTA on its own; users picking Whisper presumably want a single coherent backend). Revisit if users ask.
- **Should `FireRed` backend support a "FireRed only, no Cohere fallback" lite mode?** Not in v1. Adds 1.5 GB savings but complicates UX (errors on non-zh/en input). Wait for user demand.
- **Model storage shared across the two entry points?** Yes — both routes read `~/Library/Application Support/Murmur/Models-FireRed/`. Single source of truth, single download.

## Implementation order (preview — full plan via writing-plans next)

1. Vendor sherpa-onnx xcframework + SherpaOnnx.swift; Package.swift wiring; build green
2. `FireRedTranscriptionService` + unit test against spike fixture wav
3. `ModelBackend.fireRed` enum case + `ModelBackendFireRedTests`
4. `ModelManager` extensions: download integration, `useFireRedForChinese` state, composite-download for FireRed-backend selection
5. Routing function + `LanguageRoutingTests`
6. Wire routing into `TranscriptionService` / `AppCoordinator`
7. Settings UI: 4th engine row + sub-toggle under Cohere backends
8. Onboarding addition (4th option)
9. Error paths + alerts
10. Regression sweep + Intel Mac smoke

Each step lands as its own commit (TDD bite). CR + QA + UT per team protocol.
