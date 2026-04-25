# FireRed Chinese ASR integration — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 4th transcription backend (`ModelBackend.fireRed`) using sherpa-onnx FireRedASR2-AED int8, plus an opt-in "Use FireRed for Chinese transcription" toggle visible under Cohere backends. Both routes share the same on-disk FireRed model files.

**Architecture:** Vendor a sherpa-onnx macOS xcframework (links against the existing `onnxruntime-swift-package-manager` — coexistence verified by spike). New `FireRedTranscriptionService` actor wraps the vendored Swift API. `ModelBackend.fireRed` reuses existing `ModelManager` download/manifest/verify machinery. A new `useFireRedForChinese` UserDefaults toggle plus a pure routing function decide which backend implementation handles each request. V3 streaming always stays on Cohere (FireRed has no streaming mode).

**Tech Stack:** Swift 5.9, SwiftUI, SwiftPM (binaryTarget), XCTest, sherpa-onnx v1.12.40 (vendored), onnxruntime-swift-package-manager 1.20+ (existing).

**Spec:** `docs/superpowers/specs/2026-04-25-firered-backend-design.md`
**Spike artefacts (read-only reference):** `~/work/firered-spike/RESULTS.md`, `~/work/firered-spike/swift-spike/Sources/SpikeCLI/main.swift`

---

## File structure

| File | Responsibility | Status |
|------|----------------|--------|
| `Murmur/vendor/sherpa-onnx.xcframework/` | Static library + headers + `module.modulemap` (we add the modulemap) | created |
| `Murmur/vendor/SHERPA_ONNX_VERSION.txt` | Pinned version + URL for reproducible bumps | created |
| `Murmur/Services/Vendor/SherpaOnnx.swift` | Vendored Swift wrappers from upstream `swift-api-examples`, with one-line `import SherpaOnnxC` added | created |
| `Murmur/Package.swift` | Adds `binaryTarget` for sherpa-onnx, `linkerSettings(.linkedLibrary("c++"))` | modified |
| `Murmur/.gitattributes` | Mark xcframework `.a` as Git LFS | modified or created |
| `Murmur/Services/FireRedTranscriptionService.swift` | Actor wrapping `SherpaOnnxOfflineRecognizer`; transcribes `[Float]` samples | created |
| `Murmur/Services/ModelManager.swift` | `ModelBackend.fireRed` enum case; `useFireRedForChinese` toggle; composite-download helper for FireRed-backend selection | modified |
| `Murmur/Services/TranscriptionRouter.swift` | Pure function `BackendChoice.route(...)` over `(activeBackend, useFireRedForChinese, language, version)` | created |
| `Murmur/AppCoordinator.swift` | V1 path: route to FireRed when `route(...)` says so; fallback to Cohere on FireRed errors | modified |
| `Murmur/MurmurApp.swift` | Wire `FireRedTranscriptionService` into `replaceTranscriptionService` for `.fireRed` backend | modified |
| `Murmur/Views/SettingsView.swift` | 4th engine row; sub-toggle row visible under `.onnx`/`.huggingface`; download status for toggle's hidden FireRed download | modified |
| `Murmur/Onboarding/OnboardingView.swift` | 4th option (FireRed) — re-uses existing `ModelBackend.allCases` `ForEach`; adds icon/color/disclosure | modified |
| `Murmur/Tests/FireRedTranscriptionServiceTests.swift` | Skip-if-model-missing transcription test against `test_chinese.wav` and a new `test_chinese_en.wav` fixture | created |
| `Murmur/Tests/ModelBackendFireRedTests.swift` | Enum properties + manifest path | created |
| `Murmur/Tests/ModelManagerFireRedToggleTests.swift` | Setter rules for `useFireRedForChinese` | created |
| `Murmur/Tests/TranscriptionRouterTests.swift` | All branches of the routing function | created |
| `Murmur/test_fixtures/test_chinese_en.wav` | Same SenseVoice cn_en sample we used in spike (~460 KB) | created (Git LFS) |
| `Murmur/test_fixtures/firered_refs.json` | Expected transcripts for the FireRed test wav (lowercased, post-detok) | created |

---

## Phase 1 — Vendor sherpa-onnx & wire SwiftPM

### Task 1: Download and stage the xcframework

**Files:**
- Create: `Murmur/vendor/sherpa-onnx.xcframework/` (extracted from upstream tarball)
- Create: `Murmur/vendor/SHERPA_ONNX_VERSION.txt`

- [ ] **Step 1: Download and extract the official static xcframework**

```bash
cd /Users/ronica/work/murmur
mkdir -p Murmur/vendor
cd Murmur/vendor
curl -L -o sherpa-onnx-macos.tar.bz2 \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.40/sherpa-onnx-v1.12.40-macos-xcframework-static.tar.bz2"
tar -xjf sherpa-onnx-macos.tar.bz2
mv sherpa-onnx-v1.12.40-macos-xcframework-static/sherpa-onnx.xcframework .
rm -rf sherpa-onnx-v1.12.40-macos-xcframework-static sherpa-onnx-macos.tar.bz2
ls sherpa-onnx.xcframework/macos-arm64_x86_64/
```

Expected output:

```
Headers
libsherpa-onnx.a
```

- [ ] **Step 2: Pin the version**

Create `Murmur/vendor/SHERPA_ONNX_VERSION.txt`:

```
v1.12.40
https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.40/sherpa-onnx-v1.12.40-macos-xcframework-static.tar.bz2

Update procedure:
1. Replace the tarball URL above.
2. Re-run the download/extract steps from this plan's Task 1.
3. Re-add Murmur/vendor/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers/module.modulemap (Task 2).
4. Replace Murmur/Services/Vendor/SherpaOnnx.swift from the matching tag (Task 3) and re-add `import SherpaOnnxC`.
5. swift test --filter FireRedTranscriptionServiceTests
```

- [ ] **Step 3: Verify the static lib does NOT embed onnxruntime**

Run:

```bash
nm Murmur/vendor/sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx.a 2>/dev/null \
  | grep -E " [TSU] _OrtGetApiBase" | head -3
```

Expected (the `U` marker is what proves coexistence — sherpa-onnx imports onnxruntime symbols, doesn't bundle them):

```
                 U _OrtGetApiBase
                 U _OrtGetApiBase
                 U _OrtGetApiBase
```

If any line shows `T` or `S` instead of `U` we have a duplicate-symbol risk; STOP and re-investigate. (Spike already verified this is `U` for v1.12.40.)

- [ ] **Step 4: Commit (xcframework + version pin only — no Package.swift changes yet)**

```bash
cd /Users/ronica/work/murmur
git add Murmur/vendor/sherpa-onnx.xcframework Murmur/vendor/SHERPA_ONNX_VERSION.txt
git commit -m "chore(vendor): add sherpa-onnx v1.12.40 macOS xcframework"
```

### Task 2: Add the modulemap so SwiftPM can import the C API

**Files:**
- Create: `Murmur/vendor/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers/module.modulemap`

- [ ] **Step 1: Write the modulemap**

```
module SherpaOnnxC {
    umbrella header "sherpa-onnx/c-api/c-api.h"
    export *
    link "sherpa-onnx"
}
```

- [ ] **Step 2: Commit**

```bash
git add Murmur/vendor/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers/module.modulemap
git commit -m "chore(vendor): add module.modulemap to sherpa-onnx xcframework"
```

### Task 3: Vendor the Swift API wrapper

**Files:**
- Create: `Murmur/Services/Vendor/SherpaOnnx.swift`

- [ ] **Step 1: Download upstream `SherpaOnnx.swift` at the matching tag**

```bash
mkdir -p /Users/ronica/work/murmur/Murmur/Services/Vendor
curl -L \
  "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.12.40/swift-api-examples/SherpaOnnx.swift" \
  -o /Users/ronica/work/murmur/Murmur/Services/Vendor/SherpaOnnx.swift
wc -l /Users/ronica/work/murmur/Murmur/Services/Vendor/SherpaOnnx.swift
```

Expected: ~2249 lines.

- [ ] **Step 2: Add `import SherpaOnnxC` after `import Foundation`**

The file currently begins:

```swift
/// swift-api-examples/SherpaOnnx.swift
/// Copyright (c)  2023  Xiaomi Corporation

import Foundation  // For NSString
```

Use Edit to change:

```swift
import Foundation  // For NSString
```

to:

```swift
import Foundation  // For NSString
import SherpaOnnxC // C symbols from the vendored xcframework binary target
```

- [ ] **Step 3: Commit**

```bash
git add Murmur/Services/Vendor/SherpaOnnx.swift
git commit -m "chore(vendor): add SherpaOnnx.swift wrappers from sherpa-onnx v1.12.40"
```

### Task 4: Wire the binaryTarget in Package.swift

**Files:**
- Modify: `Murmur/Package.swift`

- [ ] **Step 1: Update Package.swift**

Read the current `Murmur/Package.swift` and replace the `targets:` block with:

```swift
    targets: [
        .binaryTarget(
            name: "SherpaOnnxC",
            path: "vendor/sherpa-onnx.xcframework"
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: [
                "HotKey",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                "SherpaOnnxC",
            ],
            path: ".",
            exclude: ["Package.swift", "Scripts", "Tests"],
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["Murmur"],
            path: "Tests"
        ),
    ]
```

- [ ] **Step 2: Build to verify the link is clean**

```bash
cd /Users/ronica/work/murmur/Murmur && swift build 2>&1 | tail -25
```

Expected: `Build complete!` (a single warning `umbrella header for module 'SherpaOnnxC' does not include header 'cxx-api.h'` is benign — `cxx-api.h` is C++ and intentionally not in the umbrella).

If you see `Undefined symbols ... _OrtGetApiBase`, the onnxruntime package isn't being linked into the same binary as sherpa-onnx — re-check the executableTarget dependencies block.

- [ ] **Step 3: Commit**

```bash
git add Murmur/Package.swift
git commit -m "build(swiftpm): wire sherpa-onnx xcframework + c++ linker"
```

### Task 5: Configure Git LFS for the static lib

**Files:**
- Modify or create: `.gitattributes` at repo root

- [ ] **Step 1: Check whether Git LFS is already used**

```bash
cd /Users/ronica/work/murmur
ls .gitattributes 2>/dev/null || echo "no .gitattributes"
git lfs version 2>&1 | head -1
```

If `git lfs version` errors out, document this in the commit and skip — the 42 MB binary is uncomfortable but not blocking. Otherwise:

- [ ] **Step 2: Add LFS tracking**

```bash
git lfs track "Murmur/vendor/sherpa-onnx.xcframework/**/libsherpa-onnx.a"
```

This appends to (or creates) `.gitattributes`. Verify:

```bash
cat .gitattributes
```

Expected line:

```
Murmur/vendor/sherpa-onnx.xcframework/**/libsherpa-onnx.a filter=lfs diff=lfs merge=lfs -text
```

- [ ] **Step 3: Migrate the existing committed binary to LFS**

```bash
git lfs migrate import --include="Murmur/vendor/sherpa-onnx.xcframework/**/libsherpa-onnx.a" --include-ref=refs/heads/feat/post-transcription-cleanup
```

If `git lfs migrate` is unavailable (older LFS), skip this step — the binary stays in regular Git history; only future bumps go to LFS via the `.gitattributes` rule.

- [ ] **Step 4: Commit `.gitattributes` only (migrate already rewrote history)**

```bash
git add .gitattributes
git diff --cached .gitattributes
git commit -m "chore: track sherpa-onnx static lib via Git LFS" || echo "(nothing to commit if migrate already wrote it)"
```

---

## Phase 2 — `FireRedTranscriptionService` (TDD)

### Task 6: Add FireRed test fixture and references

**Files:**
- Create: `Murmur/test_fixtures/test_chinese_en.wav` (~460 KB; the SenseVoice cn_en sample used in spike)
- Create: `Murmur/test_fixtures/firered_refs.json`

- [ ] **Step 1: Copy the spike's wav into fixtures**

```bash
cp /Users/ronica/work/firered-spike/audio/asr_example_cn_en.wav \
   /Users/ronica/work/murmur/Murmur/test_fixtures/test_chinese_en.wav
ls -la /Users/ronica/work/murmur/Murmur/test_fixtures/test_chinese_en.wav
file /Users/ronica/work/murmur/Murmur/test_fixtures/test_chinese_en.wav
```

Expected: `RIFF (little-endian) data, WAVE audio, Microsoft PCM, 16 bit, mono 16000 Hz`.

- [ ] **Step 2: Write `firered_refs.json`**

```json
{
  "test_chinese_en_wav_zh": {
    "text": "所有只要处理 data不管你是做 machine learning做 deep learning做 data analytics做 data science也好 scientist也好通通都要都做的基本功哦那 again先先对有一些也许对",
    "audio_dur_s": 14.749,
    "comment": "FireRedASR2-AED int8 (sherpa-onnx) output, lowercased. Captured from the spike at ~/work/firered-spike/RESULTS.md."
  },
  "test_chinese_wav_zh": {
    "text_partial": "你好",
    "comment": "Existing test_chinese.wav (~3.7 s, '你好呀,现在可以了吗?'). Just assert FireRed produces non-empty output that contains '你好' — the rest of the punctuation/space style is char-level identical to the spike's runs but we don't pin it because this fixture predates the FireRed effort."
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add Murmur/test_fixtures/test_chinese_en.wav Murmur/test_fixtures/firered_refs.json
git commit -m "test(firered): add cn_en fixture wav + reference transcripts"
```

### Task 7: Write the failing `FireRedTranscriptionServiceTests`

**Files:**
- Create: `Murmur/Tests/FireRedTranscriptionServiceTests.swift`

- [ ] **Step 1: Write the test file**

```swift
import XCTest
@testable import Murmur
import AVFoundation

/// Skip-if-model-missing tests against the sherpa-onnx FireRed v2 AED int8 model.
/// Mirrors the pattern in NativeTranscriptionTests: tests run only on dev machines
/// where the user has actually downloaded the FireRed model under
/// ~/Library/Application Support/Murmur/Models-FireRed/.
final class FireRedTranscriptionServiceTests: XCTestCase {

    // MARK: - Fixtures

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test_fixtures")
    }

    private var modelDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models-FireRed")
    }

    private lazy var refs: [String: Any] = {
        let url = fixtureDir.appendingPathComponent("firered_refs.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    // MARK: - Audio loading helper (16 kHz mono Float32)

    private func loadSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)

        if format.commonFormat == .pcmFormatFloat32 && format.sampleRate == 16000 && format.channelCount == 1 {
            guard let data = buffer.floatChannelData?[0] else {
                XCTFail("No float channel data in test wav")
                return []
            }
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        XCTFail("Test fixtures must be 16 kHz mono Float32 wav")
        return []
    }

    // MARK: - Tests

    func test_transcribe_cnEnMixed_matchesSpikeReference() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path),
                          "FireRed model not installed at \(modelDir.path) — run the app, enable the toggle, let the download finish")
        let wavURL = fixtureDir.appendingPathComponent("test_chinese_en.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))

        let svc = try FireRedTranscriptionService(modelDirectory: modelDir)
        let samples = try loadSamples(url: wavURL)

        let text = try await svc.transcribe(samples: samples, sampleRate: 16000)

        let refDict = refs["test_chinese_en_wav_zh"] as! [String: Any]
        let expected = refDict["text"] as! String
        XCTAssertEqual(text, expected,
                       "FireRed output drifted from spike reference. Update firered_refs.json only if you've intentionally changed model/version.")
    }

    func test_transcribe_shortChineseHello_containsExpected() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelDir.path))
        let wavURL = fixtureDir.appendingPathComponent("test_chinese.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wavURL.path))

        let svc = try FireRedTranscriptionService(modelDirectory: modelDir)
        let samples = try loadSamples(url: wavURL)

        let text = try await svc.transcribe(samples: samples, sampleRate: 16000)

        XCTAssertTrue(text.contains("你好"),
                      "Expected '你好' in FireRed output, got: \(text)")
        XCTAssertFalse(text.isEmpty)
    }

    func test_init_throwsWhenModelDirMissing() {
        let bogus = URL(fileURLWithPath: "/tmp/this-firered-dir-does-not-exist-\(UUID().uuidString)")
        XCTAssertThrowsError(try FireRedTranscriptionService(modelDirectory: bogus))
    }
}
```

- [ ] **Step 2: Run the test and verify they fail**

```bash
cd /Users/ronica/work/murmur/Murmur && swift test --filter FireRedTranscriptionServiceTests 2>&1 | tail -10
```

Expected: COMPILE FAIL — `FireRedTranscriptionService` not defined.

### Task 8: Implement `FireRedTranscriptionService`

**Files:**
- Create: `Murmur/Services/FireRedTranscriptionService.swift`

- [ ] **Step 1: Write the implementation**

```swift
import Foundation
import os

/// Wraps the vendored sherpa-onnx Swift API to transcribe 16 kHz mono Float32 audio
/// with FireRedASR2-AED int8.
///
/// Thread-safety: actor-isolated. The underlying `SherpaOnnxOfflineRecognizer` C
/// session is not thread-safe, so all transcribe calls serialise here.
///
/// Lifetime: holds the recognizer for the lifetime of the service. Loading the int8
/// encoder + decoder + tokens takes ~1.3 s on a Mac M-series in spike measurements,
/// so we avoid reloading per request.
actor FireRedTranscriptionService {

    private let logger = Logger(subsystem: "com.murmur.app", category: "firered")

    /// Held strongly to keep the C session alive for the actor's lifetime.
    private let recognizer: SherpaOnnxOfflineRecognizer

    /// - Parameter modelDirectory: directory containing `encoder.int8.onnx`,
    ///   `decoder.int8.onnx`, and `tokens.txt` from the
    ///   `csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26` HF repo.
    /// - Throws: `MurmurError.modelNotFound` if any required file is missing.
    init(modelDirectory: URL) throws {
        let encoder = modelDirectory.appendingPathComponent("encoder.int8.onnx").path
        let decoder = modelDirectory.appendingPathComponent("decoder.int8.onnx").path
        let tokens = modelDirectory.appendingPathComponent("tokens.txt").path

        let fm = FileManager.default
        guard fm.fileExists(atPath: encoder),
              fm.fileExists(atPath: decoder),
              fm.fileExists(atPath: tokens)
        else {
            throw MurmurError.modelNotFound
        }

        let fireRedAsr = sherpaOnnxOfflineFireRedAsrModelConfig(
            encoder: encoder, decoder: decoder
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokens, debug: 0, fireRedAsr: fireRedAsr
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig, modelConfig: modelConfig
        )

        self.recognizer = SherpaOnnxOfflineRecognizer(config: &config)
    }

    /// Transcribe a clip and return text. Mirrors the official asr.py post-processing:
    /// the raw model output is uppercase; we lowercase to match the spike reference.
    /// - Parameters:
    ///   - samples: 16 kHz mono Float32 samples in [-1, 1].
    ///   - sampleRate: must be 16000 (the int8 model's training rate).
    func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        precondition(sampleRate == 16000,
                     "FireRedTranscriptionService requires 16 kHz audio; got \(sampleRate)")

        let stream = recognizer.createStream()
        stream.acceptWaveform(samples: samples, sampleRate: sampleRate)
        recognizer.decode(stream: stream)
        let text = stream.result.text.lowercased()
        logger.info("FireRed text: \(text.prefix(200), privacy: .public)")
        return text
    }
}
```

- [ ] **Step 2: Inspect the vendored API for the exact method names**

Some method names in `SherpaOnnx.swift` may differ slightly from the spike's `recognizer.create_stream()` (Python). Run:

```bash
grep -n "func decode\|func acceptWaveform\|func createStream\|var result\|class SherpaOnnxOfflineRecognizer" \
  /Users/ronica/work/murmur/Murmur/Services/Vendor/SherpaOnnx.swift | head -20
```

If the actual names differ from `createStream` / `acceptWaveform(samples:sampleRate:)` / `decode(stream:)` / `result.text`, update `transcribe(...)` accordingly. Common variants:

- `recognizer.createStream()` vs `recognizer.createStream(hotwords:)`
- `stream.acceptWaveform(sampleRate:samples:)` vs `acceptWaveform(samples:sampleRate:)`
- `recognizer.decode(stream)` vs `recognizer.decode(stream: stream)`

**Adjust to match the vendored signatures exactly.** Spike used:

```swift
recognizer.decode(samples: array, sampleRate: Int(format.sampleRate))
```

— a one-shot helper that hides createStream/accept/decode. If `decode(samples:sampleRate:)` exists, prefer that:

```swift
let result = recognizer.decode(samples: samples, sampleRate: sampleRate)
let text = result.text.lowercased()
```

- [ ] **Step 3: Run the tests**

```bash
cd /Users/ronica/work/murmur/Murmur && swift test --filter FireRedTranscriptionServiceTests 2>&1 | tail -15
```

Expected, on a machine with FireRed model downloaded: PASS.
Expected, on CI / fresh machine: SKIPPED with the messages defined in Task 7.
Expected, in either case: `test_init_throwsWhenModelDirMissing` PASSES.

If the cn_en test fails with a text mismatch, log the actual output and STOP — do not silently update the reference. The reference is the bar.

- [ ] **Step 4: Commit**

```bash
git add Murmur/Services/FireRedTranscriptionService.swift Murmur/Tests/FireRedTranscriptionServiceTests.swift
git commit -m "feat(firered): FireRedTranscriptionService actor wrapping sherpa-onnx"
```

---

## Phase 3 — `ModelBackend.fireRed` enum case (TDD)

### Task 9: Write `ModelBackendFireRedTests`

**Files:**
- Create: `Murmur/Tests/ModelBackendFireRedTests.swift`

- [ ] **Step 1: Write the test file**

```swift
import XCTest
@testable import Murmur

final class ModelBackendFireRedTests: XCTestCase {

    func test_fireRed_isPartOfAllCases() {
        XCTAssertTrue(ModelBackend.allCases.contains(.fireRed))
    }

    func test_fireRed_rawValue() {
        XCTAssertEqual(ModelBackend.fireRed.rawValue, "fireRed")
    }

    func test_fireRed_displayName() {
        XCTAssertEqual(ModelBackend.fireRed.displayName, "FireRed (Chinese-first)")
    }

    func test_fireRed_shortName() {
        XCTAssertEqual(ModelBackend.fireRed.shortName, "FireRed")
    }

    func test_fireRed_modelRepo() {
        XCTAssertEqual(
            ModelBackend.fireRed.modelRepo,
            "csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26"
        )
    }

    func test_fireRed_modelSubdirectory() {
        XCTAssertEqual(ModelBackend.fireRed.modelSubdirectory, "Murmur/Models-FireRed")
    }

    func test_fireRed_modelSubdirectory_isUnique() {
        let subdirs = ModelBackend.allCases.map(\.modelSubdirectory)
        XCTAssertEqual(Set(subdirs).count, subdirs.count, "modelSubdirectory must be unique per backend")
    }

    func test_fireRed_requiresHFLogin_isFalse() {
        XCTAssertFalse(ModelBackend.fireRed.requiresHFLogin)
    }

    func test_fireRed_requiredFiles() {
        XCTAssertEqual(
            Set(ModelBackend.fireRed.requiredFiles),
            Set(["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"])
        )
    }

    func test_fireRed_allowPatterns_excludesTestWavs() {
        let patterns = ModelBackend.fireRed.allowPatterns ?? []
        XCTAssertTrue(patterns.contains("encoder.int8.onnx"))
        XCTAssertTrue(patterns.contains("decoder.int8.onnx"))
        XCTAssertTrue(patterns.contains("tokens.txt"))
        XCTAssertFalse(patterns.contains { $0.contains("test_wavs") },
                       "test_wavs/* should be excluded to save bandwidth")
    }

    func test_fireRed_requiredDiskSpace_isApprox1_3GB() {
        // 1.24 GB rounded up — leaves headroom for the manifest + optional config.
        XCTAssertEqual(ModelBackend.fireRed.requiredDiskSpace, 1_300_000_000)
    }

    func test_fireRed_sizeDescription() {
        XCTAssertEqual(ModelBackend.fireRed.sizeDescription, "~1.24 GB")
    }

    func test_fireRed_description_mentionsChineseAndFallback() {
        let d = ModelBackend.fireRed.description.lowercased()
        XCTAssertTrue(d.contains("chinese"), "description must mention Chinese: \(d)")
        XCTAssertTrue(d.contains("cohere") || d.contains("fall back") || d.contains("fallback"),
                      "description must explain Cohere fallback: \(d)")
    }
}
```

- [ ] **Step 2: Run and verify failures**

```bash
swift test --filter ModelBackendFireRedTests 2>&1 | tail -10
```

Expected: COMPILE FAIL — `.fireRed` case doesn't exist.

### Task 10: Add `ModelBackend.fireRed` enum case

**Files:**
- Modify: `Murmur/Services/ModelManager.swift` (lines ~27-113)

- [ ] **Step 1: Add `case fireRed` and switch arms**

Read `Murmur/Services/ModelManager.swift` around lines 27–113 to confirm current structure, then update each `switch self {}` block in the `ModelBackend` enum:

```swift
enum ModelBackend: String, CaseIterable, Identifiable, Sendable {
    case onnx
    case huggingface
    case whisper
    case fireRed                                       // NEW

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onnx: return "Standard (Recommended)"
        case .huggingface: return "High Quality"
        case .whisper: return "Whisper"
        case .fireRed: return "FireRed (Chinese-first)"     // NEW
        }
    }

    var shortName: String {
        switch self {
        case .onnx: return "Standard"
        case .huggingface: return "High Quality"
        case .whisper: return "Whisper"
        case .fireRed: return "FireRed"                     // NEW
        }
    }

    var modelRepo: String {
        switch self {
        case .onnx: return "onnx-community/cohere-transcribe-03-2026-ONNX"
        case .huggingface: return "CohereLabs/cohere-transcribe-03-2026"
        case .whisper: return "openai/whisper-large-v3-turbo"
        case .fireRed: return "csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26"
        }
    }

    var requiredDiskSpace: Int64 {
        switch self {
        case .onnx: return 1_600_000_000
        case .huggingface: return 4_200_000_000
        case .whisper: return 1_600_000_000
        case .fireRed: return 1_300_000_000             // NEW (~1.24 GB rounded up)
        }
    }

    var modelSubdirectory: String {
        switch self {
        case .onnx: return "Murmur/Models-ONNX"
        case .huggingface: return "Murmur/Models"
        case .whisper: return "Murmur/Models-Whisper"
        case .fireRed: return "Murmur/Models-FireRed"        // NEW
        }
    }

    var allowPatterns: [String]? {
        switch self {
        case .onnx: return ["onnx/encoder_model_q4f16*", "onnx/decoder_model_merged_q4f16*", "*.json"]
        case .huggingface, .whisper: return nil
        case .fireRed:                                       // NEW — excludes test_wavs/*
            return ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt", "*.json"]
        }
    }

    var requiredFiles: [String] {
        switch self {
        case .onnx: return ["config.json", "onnx/encoder_model_q4f16.onnx", "onnx/decoder_model_merged_q4f16.onnx"]
        case .huggingface, .whisper: return ["config.json", "model.safetensors"]
        case .fireRed:                                       // NEW
            return ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"]
        }
    }

    var requiresHFLogin: Bool {
        switch self {
        case .onnx, .whisper, .fireRed: return false         // NEW (not gated)
        case .huggingface: return true
        }
    }

    var sizeDescription: String {
        switch self {
        case .onnx: return "~1.5 GB"
        case .huggingface: return "~4 GB"
        case .whisper: return "~1.6 GB"
        case .fireRed: return "~1.24 GB"                     // NEW
        }
    }

    var description: String {
        switch self {
        case .onnx: return "Smaller download, fast and lightweight. Great for most users."
        case .huggingface: return "Uses your Mac's GPU for faster transcription. Larger download, requires a free account."
        case .whisper: return "OpenAI's Whisper model. Uses your Mac's GPU, great multilingual support. No account needed."
        case .fireRed:                                       // NEW
            return "Best Chinese accuracy, including dialects and Chinese-English code-switching. "
                + "Other languages fall back to Cohere ONNX (1.5 GB additional)."
        }
    }
}
```

- [ ] **Step 2: Run all relevant tests**

```bash
cd /Users/ronica/work/murmur/Murmur
swift test --filter ModelBackendFireRedTests 2>&1 | tail -10
swift test --filter P0FixTests 2>&1 | tail -10
swift test --filter ModelSwitchingTests 2>&1 | tail -10
```

Expected: all PASS. P0FixTests + ModelSwitchingTests iterate `ModelBackend.allCases`; they implicitly check that the new case doesn't break invariants like unique subdirectories.

- [ ] **Step 3: Commit**

```bash
git add Murmur/Services/ModelManager.swift Murmur/Tests/ModelBackendFireRedTests.swift
git commit -m "feat(model): add ModelBackend.fireRed (sherpa-onnx FireRedASR2-AED int8)"
```

---

## Phase 4 — `useFireRedForChinese` toggle state (TDD)

### Task 11: Write `ModelManagerFireRedToggleTests`

**Files:**
- Create: `Murmur/Tests/ModelManagerFireRedToggleTests.swift`

- [ ] **Step 1: Write the test file**

```swift
import XCTest
import Combine
@testable import Murmur

@MainActor
final class ModelManagerFireRedToggleTests: XCTestCase {

    private let key = "useFireRedForChinese"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - Default

    func test_default_isFalse_whenUserDefaultsUnset() {
        let mm = ModelManager()
        XCTAssertFalse(mm.useFireRedForChinese)
    }

    func test_initial_readsPersistedTrue() {
        UserDefaults.standard.set(true, forKey: key)
        // FireRed model must already be present for ON to be honoured at init.
        // We don't have a real model here; verify the persistence key is read.
        let mm = ModelManager()
        // If FireRed model is missing on disk, `useFireRedForChinese` MUST stay
        // false on init even if UserDefaults says true — guards against a stale
        // toggle for users who deleted the model directory manually.
        if FileManager.default.fileExists(atPath: mm.modelDirectory(for: .fireRed).path) {
            // Real machines with FireRed installed: honour the persisted value.
            XCTAssertTrue(mm.useFireRedForChinese)
        } else {
            // CI / fresh machines: must be false.
            XCTAssertFalse(mm.useFireRedForChinese)
        }
    }

    // MARK: - Setter rules

    func test_setUseFireRedForChinese_false_alwaysSucceeds() {
        let mm = ModelManager()
        // Pre-set true via UserDefaults to simulate prior commit.
        UserDefaults.standard.set(true, forKey: key)
        let mm2 = ModelManager()
        let ok = mm2.setUseFireRedForChinese(false)
        XCTAssertTrue(ok)
        XCTAssertFalse(mm2.useFireRedForChinese)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
    }

    func test_setUseFireRedForChinese_true_refused_whenFireRedNotDownloaded() {
        let mm = ModelManager()
        // FireRed not downloaded — the setter must NOT commit ON; the caller
        // is responsible for invoking the download flow first.
        let ok = mm.setUseFireRedForChinese(true)
        XCTAssertFalse(ok, "Toggle ON must be refused if FireRed model is missing")
        XCTAssertFalse(mm.useFireRedForChinese)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
    }

    // The "refused during active download" rule is identical to setActiveBackend's
    // existing behavior; ModelSwitchingTests already covers the symmetric case.
    // We add a parallel assertion here.
    func test_setUseFireRedForChinese_true_refused_duringActiveDownload() {
        let mm = ModelManager()
        // Simulate active download by forcing state. ModelManager exposes a
        // setter only via download(); rather than spinning up a real download,
        // we use the `__testing_setState` seam (added in Task 12 below).
        mm.__testing_setState(.downloading(progress: 0.5, bytesPerSec: 0))
        let ok = mm.setUseFireRedForChinese(true)
        XCTAssertFalse(ok)
    }

    // MARK: - committedUseFireRedChange publisher

    func test_committedChange_firesOnFalseToggle() {
        let mm = ModelManager()
        UserDefaults.standard.set(true, forKey: key)
        let mm2 = ModelManager()
        var received: [Bool] = []
        let cancellable = mm2.committedUseFireRedChange.sink { received.append($0) }
        defer { cancellable.cancel() }
        _ = mm2.setUseFireRedForChinese(false)
        XCTAssertEqual(received, [false])
    }

    func test_committedChange_doesNotFire_whenAlreadyAtTargetState() {
        let mm = ModelManager()
        var received: [Bool] = []
        let cancellable = mm.committedUseFireRedChange.sink { received.append($0) }
        defer { cancellable.cancel() }
        _ = mm.setUseFireRedForChinese(false) // already false
        XCTAssertEqual(received, [], "Setter must short-circuit when state is unchanged")
    }
}
```

- [ ] **Step 2: Run and verify failure**

```bash
swift test --filter ModelManagerFireRedToggleTests 2>&1 | tail -15
```

Expected: COMPILE FAIL — `useFireRedForChinese`, `setUseFireRedForChinese`, `committedUseFireRedChange`, `__testing_setState` don't exist.

### Task 12: Implement the toggle on `ModelManager`

**Files:**
- Modify: `Murmur/Services/ModelManager.swift`

- [ ] **Step 1: Add stored state and publisher**

Find the section that declares `@Published private(set) var activeBackend` and the `committedBackendChange` publisher (around lines 229–245). Add immediately after:

```swift
    /// Whether to route Chinese audio to FireRed when the active backend is a
    /// Cohere variant. OFF by default. Persisted in UserDefaults under
    /// `"useFireRedForChinese"`. Callers MUST go through `setUseFireRedForChinese(_:)`
    /// — direct assignment is intentionally not exposed so the gating logic
    /// (download-active, model-not-downloaded) runs every time.
    @Published private(set) var useFireRedForChinese: Bool

    /// Emits when `setUseFireRedForChinese(_:)` actually commits a change.
    /// Subscribers (e.g. AppCoordinator) can re-evaluate the routing function.
    let committedUseFireRedChange = PassthroughSubject<Bool, Never>()
```

- [ ] **Step 2: Initialise in `init()`**

Find `init()` (search for `activeBackend = ...`) and add right after the `activeBackend` assignment:

```swift
        // Read persisted toggle, but downgrade to OFF if the FireRed model is
        // not actually on disk — guards against stale state for users who
        // deleted the model directory manually.
        let persistedToggle = UserDefaults.standard.bool(forKey: "useFireRedForChinese")
        let fireRedDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ModelBackend.fireRed.modelSubdirectory)
        let fireRedPresent = FileManager.default.fileExists(atPath: fireRedDir.path)
        self.useFireRedForChinese = persistedToggle && fireRedPresent
```

- [ ] **Step 3: Add the setter**

Add right after `setActiveBackend(_:)` (around line 268):

```swift
    /// Attempt to set the FireRed-for-Chinese toggle.
    ///
    /// - Parameter newValue: desired toggle state.
    /// - Returns: `true` if the change was accepted and persisted; `false` if:
    ///   - a download or verification is in progress (newValue=true rejected), OR
    ///   - newValue=true but the FireRed model is not on disk (caller must
    ///     trigger a `download(for: .fireRed)` first).
    @discardableResult
    func setUseFireRedForChinese(_ newValue: Bool) -> Bool {
        // Short-circuit on no-op — match setActiveBackend's behavior so we
        // don't fire spurious committedUseFireRedChange events.
        guard newValue != useFireRedForChinese else { return true }

        if newValue == true {
            guard !isDownloadActive else {
                logger.warning("Refused FireRed toggle ON — download in progress")
                return false
            }
            guard isModelDownloaded(for: .fireRed) else {
                logger.warning("Refused FireRed toggle ON — model not downloaded")
                return false
            }
        }

        useFireRedForChinese = newValue
        UserDefaults.standard.set(newValue, forKey: "useFireRedForChinese")
        committedUseFireRedChange.send(newValue)
        return true
    }
```

- [ ] **Step 4: Add the `__testing_setState` seam (DEBUG-only)**

Find the existing `#if DEBUG` block (search for `__testing_setModelDirectory`) — there is already a testing-seam pattern in this file. Add inside the same `#if DEBUG` region:

```swift
#if DEBUG
    func __testing_setState(_ newState: ModelState) {
        self.state = newState
    }
#endif
```

If no `#if DEBUG` block exists in `ModelManager.swift`, create one at the bottom of the class with both this method and any others that already use a `__testing_` prefix. The intent is a per-test override, not production-shipping code.

- [ ] **Step 5: Run the toggle tests**

```bash
swift test --filter ModelManagerFireRedToggleTests 2>&1 | tail -15
```

Expected: ALL PASS.

- [ ] **Step 6: Run regression suite**

```bash
swift test --filter ModelSwitchingTests 2>&1 | tail -5
swift test --filter ManifestVerificationTests 2>&1 | tail -5
swift test --filter DownloadCancelIntegrationTests 2>&1 | tail -5
```

Expected: all PASS — toggle additions are additive, must not break existing manager tests.

- [ ] **Step 7: Commit**

```bash
git add Murmur/Services/ModelManager.swift Murmur/Tests/ModelManagerFireRedToggleTests.swift
git commit -m "feat(model): useFireRedForChinese toggle on ModelManager"
```

---

## Phase 5 — Routing function (TDD, pure)

### Task 13: Write `TranscriptionRouterTests`

**Files:**
- Create: `Murmur/Tests/TranscriptionRouterTests.swift`

- [ ] **Step 1: Write the tests**

```swift
import XCTest
@testable import Murmur

final class TranscriptionRouterTests: XCTestCase {

    typealias Choice = TranscriptionRouter.BackendChoice

    // MARK: - V3 streaming always Cohere

    func test_v3Streaming_alwaysRoutesToCohere_evenWithFireRedActive() {
        let c = TranscriptionRouter.route(
            activeBackend: .fireRed,
            useFireRedForChinese: true,
            language: "zh",
            version: .v3Streaming
        )
        XCTAssertEqual(c, .cohereStreaming)
    }

    func test_v3Streaming_alwaysRoutesToCohere_withToggleOn() {
        let c = TranscriptionRouter.route(
            activeBackend: .onnx,
            useFireRedForChinese: true,
            language: "zh",
            version: .v3Streaming
        )
        XCTAssertEqual(c, .cohereStreaming)
    }

    // MARK: - FireRed backend

    func test_fireRedBackend_zh_routesToFireRed() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .fireRed, useFireRedForChinese: false,
                                      language: "zh", version: .v1FullPass),
            .fireRed
        )
    }

    func test_fireRedBackend_en_routesToFireRed() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .fireRed, useFireRedForChinese: false,
                                      language: "en", version: .v1FullPass),
            .fireRed
        )
    }

    func test_fireRedBackend_ja_fallsBackToCohereONNX() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .fireRed, useFireRedForChinese: false,
                                      language: "ja", version: .v1FullPass),
            .cohereONNX
        )
    }

    func test_fireRedBackend_fr_fallsBackToCohereONNX() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .fireRed, useFireRedForChinese: false,
                                      language: "fr", version: .v1FullPass),
            .cohereONNX
        )
    }

    // MARK: - Toggle under Cohere ONNX

    func test_onnxBackend_toggleOn_zh_routesToFireRed() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .onnx, useFireRedForChinese: true,
                                      language: "zh", version: .v1FullPass),
            .fireRed
        )
    }

    func test_onnxBackend_toggleOn_en_routesToOnnx() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .onnx, useFireRedForChinese: true,
                                      language: "en", version: .v1FullPass),
            .existing(.onnx)
        )
    }

    func test_onnxBackend_toggleOn_ja_routesToOnnx() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .onnx, useFireRedForChinese: true,
                                      language: "ja", version: .v1FullPass),
            .existing(.onnx)
        )
    }

    func test_onnxBackend_toggleOff_zh_routesToOnnx() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .onnx, useFireRedForChinese: false,
                                      language: "zh", version: .v1FullPass),
            .existing(.onnx)
        )
    }

    // MARK: - Toggle under Cohere HF

    func test_hfBackend_toggleOn_zh_routesToFireRed() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .huggingface, useFireRedForChinese: true,
                                      language: "zh", version: .v1FullPass),
            .fireRed
        )
    }

    func test_hfBackend_toggleOn_en_routesToHF() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .huggingface, useFireRedForChinese: true,
                                      language: "en", version: .v1FullPass),
            .existing(.huggingface)
        )
    }

    // MARK: - Whisper never gets toggle

    func test_whisperBackend_toggleOn_zh_stillRoutesToWhisper() {
        // The toggle UI is hidden under Whisper, but defensively if state is
        // somehow corrupted we still keep Whisper as the choice.
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .whisper, useFireRedForChinese: true,
                                      language: "zh", version: .v1FullPass),
            .existing(.whisper)
        )
    }

    func test_whisperBackend_zh_routesToWhisper() {
        XCTAssertEqual(
            TranscriptionRouter.route(activeBackend: .whisper, useFireRedForChinese: false,
                                      language: "zh", version: .v1FullPass),
            .existing(.whisper)
        )
    }
}
```

- [ ] **Step 2: Run and verify failure**

```bash
swift test --filter TranscriptionRouterTests 2>&1 | tail -10
```

Expected: COMPILE FAIL — `TranscriptionRouter`, `BackendChoice`, `TranscriptionVersion` don't exist yet.

### Task 14: Implement `TranscriptionRouter`

**Files:**
- Create: `Murmur/Services/TranscriptionRouter.swift`

- [ ] **Step 1: Write the implementation**

```swift
import Foundation

/// Pure routing decision: given the user's settings and the request shape,
/// pick which transcription backend implementation handles this audio.
///
/// No I/O, no async, no logging — easy to test exhaustively.
enum TranscriptionRouter {

    /// V1 = full-pass (record then transcribe); V3 = streaming.
    /// V3 always uses Cohere because FireRed has no streaming mode.
    enum TranscriptionVersion: Sendable {
        case v1FullPass
        case v3Streaming
    }

    /// Where to send the request.
    enum BackendChoice: Equatable, Sendable {
        /// Use the FireRed sherpa-onnx pipeline.
        case fireRed
        /// Use the existing V3 Cohere streaming pipeline (StreamingTranscriptionCoordinator).
        case cohereStreaming
        /// Use the Cohere ONNX backend specifically (FireRed-backend's fallback for non-zh/en).
        case cohereONNX
        /// Use whichever backend is active — `.onnx`, `.huggingface`, or `.whisper`.
        case existing(ModelBackend)
    }

    /// - Returns: which backend should handle this request.
    static func route(
        activeBackend: ModelBackend,
        useFireRedForChinese: Bool,
        language: String,
        version: TranscriptionVersion
    ) -> BackendChoice {
        // V3 streaming always uses Cohere — FireRed has no streaming mode.
        if version == .v3Streaming {
            return .cohereStreaming
        }

        // FireRed backend handles zh/en; everything else falls back to Cohere ONNX.
        if activeBackend == .fireRed {
            if language == "zh" || language == "en" {
                return .fireRed
            }
            return .cohereONNX
        }

        // Cohere backends (onnx + hf) with toggle ON: route Chinese to FireRed.
        if (activeBackend == .onnx || activeBackend == .huggingface)
            && useFireRedForChinese
            && language == "zh"
        {
            return .fireRed
        }

        // Whisper, plus all other (language, toggle) combinations: unchanged.
        return .existing(activeBackend)
    }
}
```

- [ ] **Step 2: Run all the routing tests**

```bash
swift test --filter TranscriptionRouterTests 2>&1 | tail -10
```

Expected: ALL PASS.

- [ ] **Step 3: Commit**

```bash
git add Murmur/Services/TranscriptionRouter.swift Murmur/Tests/TranscriptionRouterTests.swift
git commit -m "feat(routing): TranscriptionRouter — backend choice as a pure function"
```

---

## Phase 6 — Wire routing into AppCoordinator

### Task 15: Hold a FireRed service alongside the existing one

**Files:**
- Modify: `Murmur/AppCoordinator.swift`

- [ ] **Step 1: Add FireRed service property**

Find the property declarations near the top of the `AppCoordinator` class (search for `private(set) var streamingCoordinator`). Add immediately after:

```swift
    /// FireRed transcription service. Lazily created when first needed AND
    /// when the FireRed model is downloaded. nil until either condition fails.
    /// Replaced when the model directory changes (for tests via __testing seams).
    private var fireRed: FireRedTranscriptionService?
    private var fireRedModelDirectory: URL?
```

- [ ] **Step 2: Add a setter the app can call when toggle commits**

Right after `replaceTranscriptionService(_:)` (around line 183), add:

```swift
    /// Wire up (or tear down) the FireRed service. Called from `MurmurApp` in
    /// response to `committedUseFireRedChange` and `committedBackendChange`.
    /// Passing `nil` releases the recognizer.
    func setFireRedService(_ service: FireRedTranscriptionService?, modelDirectory: URL?) {
        self.fireRed = service
        self.fireRedModelDirectory = modelDirectory
    }
```

- [ ] **Step 3: Add `routeAndTranscribeV1` helper**

Find `transcribeWithAutoDetectIfNeeded` (around line 1061). Add a new private method right above it:

```swift
    /// V1 transcribe path that consults `TranscriptionRouter` and dispatches to
    /// either FireRed or the existing transcription service. On FireRed errors
    /// we fall back to Cohere for THIS request only and log the failure.
    private func routedTranscribeV1(wav: URL, language: String) async throws -> TranscriptionResult {
        let modelManager = self.modelManager
        let choice = TranscriptionRouter.route(
            activeBackend: modelManager?.activeBackend ?? .onnx,
            useFireRedForChinese: modelManager?.useFireRedForChinese ?? false,
            language: language,
            version: .v1FullPass
        )

        switch choice {
        case .fireRed:
            // Need a service AND samples. Load samples once; on FireRed error
            // we re-load not at all — Cohere needs the URL, not samples.
            guard let svc = fireRed else {
                Self.log.warning("FireRed routing chosen but service not initialised — falling back to Cohere")
                return try await transcription.transcribe(audioURL: wav, language: language)
            }
            do {
                let samples = try Self.loadSamples16k(url: wav)
                let text = try await svc.transcribe(samples: samples, sampleRate: 16000)
                let lang: DetectedLanguage = (language == "zh") ? .chinese : .english
                return TranscriptionResult(text: text, language: lang, durationMs: 0)
            } catch {
                Self.log.warning("FireRed inference failed, falling back to Cohere: \(String(describing: error), privacy: .public)")
                return try await transcription.transcribe(audioURL: wav, language: language)
            }

        case .cohereONNX, .cohereStreaming, .existing:
            // Existing path — the active service is already correct because
            // MurmurApp swaps it on backend changes.
            return try await transcription.transcribe(audioURL: wav, language: language)
        }
    }
```

- [ ] **Step 4: Add the audio-loading helper**

The helper is used only by `routedTranscribeV1`. Add as a static func at the end of the class body (just before the closing `}`):

```swift
    /// Load 16 kHz mono Float32 samples from a wav. Mirrors
    /// NativeTranscriptionService.loadAudio for the same conversion semantics.
    fileprivate static func loadSamples16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        if srcFormat.sampleRate == 16000 && srcFormat.channelCount == 1
            && srcFormat.commonFormat == .pcmFormatFloat32 {
            let frameCount = AVAudioFrameCount(file.length)
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
                throw MurmurError.transcriptionFailed("Failed to create audio buffer")
            }
            try file.read(into: buf)
            guard let data = buf.floatChannelData?[0] else {
                throw MurmurError.transcriptionFailed("No audio data")
            }
            return Array(UnsafeBufferPointer(start: data, count: Int(buf.frameLength)))
        }

        guard let conv = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw MurmurError.transcriptionFailed("Cannot create audio converter")
        }
        let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: 4096)!
        var allSamples = [Float]()
        var convError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            do {
                inBuf.frameLength = 0
                try file.read(into: inBuf)
                if inBuf.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuf
            } catch { outStatus.pointee = .endOfStream; return nil }
        }
        var status: AVAudioConverterOutputStatus
        repeat {
            let chunk = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096)!
            status = conv.convert(to: chunk, error: &convError, withInputFrom: inputBlock)
            if let data = chunk.floatChannelData?[0], chunk.frameLength > 0 {
                allSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(chunk.frameLength)))
            }
        } while status == .haveData
        if allSamples.isEmpty {
            throw MurmurError.transcriptionFailed("No audio data after conversion")
        }
        return allSamples
    }
```

- [ ] **Step 5: Add an import for AVFoundation if missing**

Search for `import AVFoundation` near the top of `AppCoordinator.swift`. If absent, add it.

- [ ] **Step 6: Hold a weak reference to ModelManager**

The router needs `modelManager?.activeBackend`. Search the AppCoordinator for `modelManager` — if it's not already a property, add a weak reference:

```swift
    /// Set by MurmurApp at construction time; the coordinator queries the
    /// router via this manager.
    weak var modelManager: ModelManager?
```

If it already exists (as a stored or weak property), skip this step. Either way, ensure `MurmurApp.init` sets `coordinator.modelManager = mm` after `let coord = AppCoordinator(...)`.

- [ ] **Step 7: Replace the V1 transcribe call in `stopAndTranscribeV1`**

Find line 749:

```swift
            let result = try await transcribeWithAutoDetectIfNeeded(wav: wav, initialLang: initialLang)
```

`transcribeWithAutoDetectIfNeeded` calls `self.transcription.transcribe(...)` directly twice. Update those two call sites to use `self.routedTranscribeV1(wav:language:)` instead. Specifically, in `transcribeWithAutoDetectIfNeeded` (line 1061), replace:

```swift
        let result1 = try await withTimeout(seconds: 120, operation: "transcription") {
            try await self.transcription.transcribe(audioURL: wav, language: initialLang)
        }
```

with:

```swift
        let result1 = try await withTimeout(seconds: 120, operation: "transcription") {
            try await self.routedTranscribeV1(wav: wav, language: initialLang)
        }
```

And in the same function, replace:

```swift
            let result2 = try await withTimeout(seconds: 120, operation: "transcription-retry") {
                try await self.transcription.transcribe(audioURL: wav, language: detectedCode)
            }
```

with:

```swift
            let result2 = try await withTimeout(seconds: 120, operation: "transcription-retry") {
                try await self.routedTranscribeV1(wav: wav, language: detectedCode)
            }
```

- [ ] **Step 8: Build and run existing AppCoordinator tests**

```bash
cd /Users/ronica/work/murmur/Murmur && swift build 2>&1 | tail -5
swift test --filter AppCoordinatorTests 2>&1 | tail -10
```

Expected: build PASS, AppCoordinatorTests PASS. The coordinator changes are backwards-compatible because `fireRed == nil` makes `routedTranscribeV1` fall through to the existing `transcription.transcribe` path.

- [ ] **Step 9: Commit**

```bash
git add Murmur/AppCoordinator.swift
git commit -m "feat(coord): route V1 via TranscriptionRouter; FireRed-aware dispatch"
```

### Task 16: Wire FireRed service lifecycle in MurmurApp

**Files:**
- Modify: `Murmur/MurmurApp.swift`

- [ ] **Step 1: Add a helper that builds a FireRedTranscriptionService when applicable**

In `MurmurApp.init()`, after `let coord = AppCoordinator(transcription: ts)`:

```swift
        coord.modelManager = mm

        // Build FireRed service if either route is active and the model is on disk.
        if Self.shouldHaveFireRed(modelManager: mm) {
            if let svc = try? FireRedTranscriptionService(modelDirectory: mm.modelDirectory(for: .fireRed)) {
                coord.setFireRedService(svc, modelDirectory: mm.modelDirectory(for: .fireRed))
            }
        }
```

Add the static helper at the bottom of the struct (before the final `}`):

```swift
    /// FireRed should be loaded if (a) the FireRed backend is active, OR
    /// (b) the cross-backend toggle is on. Both require the FireRed model
    /// to be present on disk — we re-check at construction time to guard
    /// against stale UserDefaults.
    private static func shouldHaveFireRed(modelManager mm: ModelManager) -> Bool {
        let modelExists = FileManager.default.fileExists(
            atPath: mm.modelDirectory(for: .fireRed).path
        )
        guard modelExists else { return false }
        if mm.activeBackend == .fireRed { return true }
        if mm.useFireRedForChinese && (mm.activeBackend == .onnx || mm.activeBackend == .huggingface) {
            return true
        }
        return false
    }
```

- [ ] **Step 2: React to the toggle and the backend committed-change publishers**

Find the `.onReceive(modelManager.committedBackendChange)` block (around line 85). Wrap its body with FireRed re-wiring; after the existing service swap:

```swift
                .onReceive(modelManager.committedBackendChange) { newBackend in
                    let newPath = modelManager.modelDirectory(for: newBackend)
                    let newService: any TranscriptionServiceProtocol = newBackend == .onnx
                        ? NativeTranscriptionService(modelPath: newPath)
                        : TranscriptionService(modelPath: newPath)
                    coordinator.replaceTranscriptionService(newService)

                    // Re-evaluate FireRed presence after a backend change.
                    if Self.shouldHaveFireRed(modelManager: modelManager) {
                        if let svc = try? FireRedTranscriptionService(
                            modelDirectory: modelManager.modelDirectory(for: .fireRed)
                        ) {
                            coordinator.setFireRedService(
                                svc, modelDirectory: modelManager.modelDirectory(for: .fireRed)
                            )
                        }
                    } else {
                        coordinator.setFireRedService(nil, modelDirectory: nil)
                    }
                }
                .onReceive(modelManager.committedUseFireRedChange) { _ in
                    if Self.shouldHaveFireRed(modelManager: modelManager) {
                        if let svc = try? FireRedTranscriptionService(
                            modelDirectory: modelManager.modelDirectory(for: .fireRed)
                        ) {
                            coordinator.setFireRedService(
                                svc, modelDirectory: modelManager.modelDirectory(for: .fireRed)
                            )
                        }
                    } else {
                        coordinator.setFireRedService(nil, modelDirectory: nil)
                    }
                }
```

- [ ] **Step 3: Build and verify**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Murmur/MurmurApp.swift
git commit -m "feat(app): wire FireRedTranscriptionService lifecycle"
```

---

## Phase 7 — Settings UI (4th engine row + sub-toggle)

### Task 17: Add the FireRed engine row + sub-toggle

**Files:**
- Modify: `Murmur/Views/SettingsView.swift`

- [ ] **Step 1: Add the FireRed row to the Speech Engine section**

Find `private var modelTab` (around line 211). Replace the existing block:

```swift
        Form {
            Section("Speech Engine") {
                engineRow(.onnx)

                DisclosureGroup("Advanced", isExpanded: $showAdvancedEngines) {
                    engineRow(.huggingface)
                    engineRow(.whisper)
                }
            }
```

with:

```swift
        Form {
            Section("Speech Engine") {
                engineRow(.onnx)
                if modelManager.activeBackend == .onnx {
                    fireRedToggleRow
                }

                DisclosureGroup("Advanced", isExpanded: $showAdvancedEngines) {
                    engineRow(.huggingface)
                    if modelManager.activeBackend == .huggingface {
                        fireRedToggleRow
                    }
                    engineRow(.whisper)
                    engineRow(.fireRed)
                }
            }
```

- [ ] **Step 2: Add the toggle row view**

Right after `engineRow(_ backend:)` (around line 583), add:

```swift
    /// Sub-toggle visible under Cohere ONNX or HF backends. Routes Chinese
    /// audio to FireRed when ON. Triggers a download if the FireRed model is
    /// not yet on disk.
    @ViewBuilder
    private var fireRedToggleRow: some View {
        let isOn = modelManager.useFireRedForChinese
        let fireRedReady = modelManager.isModelDownloaded(for: .fireRed)
        let isDownloadingFireRed: Bool = {
            // Reuse main download state — toggle's download piggybacks on the
            // primary download flow because there's only one active subprocess.
            if case .downloading = modelManager.state, modelManager.activeBackend == .onnx
                || modelManager.activeBackend == .huggingface {
                // Cannot directly distinguish a FireRed download from a Cohere
                // re-download here without extra state. Show generic in-flight.
                return modelManager.statusMessage.contains("FireRed")
            }
            return false
        }()

        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { isOn },
                set: { newValue in
                    if newValue && !fireRedReady {
                        Task { await downloadFireRedFromToggle() }
                    } else {
                        _ = modelManager.setUseFireRedForChinese(newValue)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use FireRed for Chinese transcription")
                        .font(.body)
                    Text("\(ModelBackend.fireRed.sizeDescription) additional · "
                         + "Routes Chinese audio to FireRed for better accuracy. "
                         + "Other languages stay on Cohere. V1 only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(modelManager.isDownloadActive)

            if isDownloadingFireRed {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.leading, 24)
    }

    /// Download the FireRed model on behalf of a user enabling the toggle.
    /// On success, set the toggle ON. On failure or cancellation, leave it OFF.
    private func downloadFireRedFromToggle() async {
        // Stash the current backend so we can restore after the download.
        let savedBackend = modelManager.activeBackend
        modelManager.statusMessage = "Downloading FireRed model..."
        do {
            // Temporarily flip activeBackend to .fireRed so download() targets it.
            // This is a small lie that we revert before signalling the toggle.
            // Use the dedicated download helper if/when we add it; for now use
            // the existing setActiveBackend + download() path.
            _ = modelManager.setActiveBackend(.fireRed)
            try await modelManager.download()
            _ = modelManager.setActiveBackend(savedBackend)
            _ = modelManager.setUseFireRedForChinese(true)
        } catch {
            _ = modelManager.setActiveBackend(savedBackend)
            // alert handled by ModelManager via existing error path
        }
    }
```

- [ ] **Step 3: Build and visually verify**

```bash
cd /Users/ronica/work/murmur/Murmur && swift build 2>&1 | tail -5
```

Expected: clean build.

Then run the app from Xcode (or `open dist/Murmur.app` after build) and:
1. Open Settings → Speech Engine section
2. Confirm: with Standard active, the toggle row appears under it
3. Switch to High Quality → toggle row appears under it
4. Switch to Whisper → no toggle row
5. Open Advanced disclosure → FireRed appears as a 4th engine

Smoke-test only — full integration tests come later.

- [ ] **Step 4: Commit**

```bash
git add Murmur/Views/SettingsView.swift
git commit -m "feat(settings): FireRed 4th engine row + sub-toggle under Cohere"
```

---

## Phase 8 — Onboarding addition

### Task 18: Adjust onboarding for FireRed's icon and color

**Files:**
- Modify: `Murmur/Onboarding/OnboardingView.swift`

- [ ] **Step 1: Add FireRed icon and color cases**

Find `private func backendIcon(_:)` (around line 625) and `private func backendColor(_:)` (around line 633). Add the FireRed case:

```swift
    private func backendIcon(_ backend: ModelBackend) -> String {
        switch backend {
        case .onnx: return "hare.fill"
        case .huggingface: return "wand.and.stars"
        case .whisper: return "waveform"
        case .fireRed: return "flame.fill"                  // NEW
        }
    }

    private func backendColor(_ backend: ModelBackend) -> Color {
        switch backend {
        case .onnx: return .blue
        case .huggingface: return .purple
        case .whisper: return .orange
        case .fireRed: return .red                          // NEW
        }
    }
```

- [ ] **Step 2: Verify the FireRed card content displays correctly**

Find `backendCardContent(_:isDownloaded:isLocked:)` (around line 585). The existing logic uses `backend.sizeDescription` and `backend.description`, both of which now resolve correctly for `.fireRed`. The `if backend == .onnx` line at 590 only adds the "(Recommended)" badge to ONNX — this is correct behavior; FireRed should not claim "Recommended".

If the onboarding card has any hard-coded list of three backends elsewhere, update to include `.fireRed`. Search:

```bash
grep -n "case .onnx\|case .huggingface\|case .whisper" /Users/ronica/work/murmur/Murmur/Onboarding/OnboardingView.swift | grep -v "fireRed"
```

Expected: only the cases we already updated should appear. If there are any unhandled `switch` statements, add `.fireRed` cases there.

- [ ] **Step 3: Build and smoke-test onboarding**

```bash
swift build 2>&1 | tail -5
```

Run the app and trigger onboarding (delete `~/Library/Preferences/com.murmur.app.plist` `onboardingCompleted` key, or use the test entry point). Confirm FireRed appears as a 4th option in the model choice step.

- [ ] **Step 4: Commit**

```bash
git add Murmur/Onboarding/OnboardingView.swift
git commit -m "feat(onboarding): add FireRed as 4th backend option"
```

---

## Phase 9 — Error paths (focused integration tests)

### Task 19: Test FireRed initialization failure → Cohere fallback

**Files:**
- Create: `Murmur/Tests/FireRedFallbackTests.swift`

- [ ] **Step 1: Write a focused fallback test**

```swift
import XCTest
@testable import Murmur

@MainActor
final class FireRedFallbackTests: XCTestCase {

    func test_fireRedInitFailure_throwsModelNotFound() {
        let bogusURL = URL(fileURLWithPath: "/tmp/nope-firered-\(UUID().uuidString)")
        do {
            _ = try FireRedTranscriptionService(modelDirectory: bogusURL)
            XCTFail("Expected init to throw modelNotFound")
        } catch let err as MurmurError {
            if case .modelNotFound = err { return }
            XCTFail("Expected .modelNotFound, got \(err)")
        } catch {
            XCTFail("Expected MurmurError.modelNotFound, got \(error)")
        }
    }

    /// Toggle flips back to OFF when the user enables it but the model isn't
    /// downloaded and no download has been kicked off.
    func test_setUseFireRedForChinese_whenModelMissing_returnsFalseAndStaysOff() {
        UserDefaults.standard.removeObject(forKey: "useFireRedForChinese")
        let mm = ModelManager()
        XCTAssertFalse(mm.useFireRedForChinese)
        let ok = mm.setUseFireRedForChinese(true)
        XCTAssertFalse(ok)
        XCTAssertFalse(mm.useFireRedForChinese)
    }
}
```

- [ ] **Step 2: Run**

```bash
swift test --filter FireRedFallbackTests 2>&1 | tail -10
```

Expected: PASS — both behaviors are already implemented in earlier tasks.

- [ ] **Step 3: Commit**

```bash
git add Murmur/Tests/FireRedFallbackTests.swift
git commit -m "test(firered): init failure + toggle-without-model contract"
```

### Task 20: Add structured error logging in `routedTranscribeV1`

**Files:**
- Modify: `Murmur/AppCoordinator.swift` (the `routedTranscribeV1` we wrote in Task 15)

- [ ] **Step 1: Add a once-per-session warning flag**

The current implementation logs every FireRed failure. Add a once-per-session flag so we don't spam logs if FireRed is consistently failing — switch to Cohere quietly after the first warning.

Find `routedTranscribeV1` and add a property:

```swift
    /// True after we've logged the first FireRed failure this session — keeps
    /// the log readable when the model is missing or broken.
    private var hasLoggedFireRedFailureThisSession = false
```

Update the catch block:

```swift
            } catch {
                if !hasLoggedFireRedFailureThisSession {
                    hasLoggedFireRedFailureThisSession = true
                    Self.log.warning("FireRed inference failed (further failures suppressed this session): \(String(describing: error), privacy: .public)")
                }
                return try await transcription.transcribe(audioURL: wav, language: language)
            }
```

- [ ] **Step 2: Reset flag when service is replaced**

In `setFireRedService(_:modelDirectory:)`:

```swift
    func setFireRedService(_ service: FireRedTranscriptionService?, modelDirectory: URL?) {
        self.fireRed = service
        self.fireRedModelDirectory = modelDirectory
        self.hasLoggedFireRedFailureThisSession = false
    }
```

- [ ] **Step 3: Build and run AppCoordinatorTests**

```bash
swift build 2>&1 | tail -5
swift test --filter AppCoordinatorTests 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Murmur/AppCoordinator.swift
git commit -m "feat(coord): suppress repeat FireRed failure logs once per session"
```

---

## Phase 10 — Regression sweep + final polish

### Task 21: Full test suite

**Files:** none — this is a verification task.

- [ ] **Step 1: Run the full suite**

```bash
cd /Users/ronica/work/murmur/Murmur && swift test 2>&1 | tail -40
```

Expected: ALL PASS or SKIPPED. Specifically check:
- `Phase0SpikeTests` — PASS
- `ModelSwitchingTests` — PASS (now iterates 4 cases)
- `B3B4FixTests`, `LanguageBadgeTests`, `PunctuationCleanupTests`, `TranscriptionCorrectionTests` — PASS
- `V3Phase0Tests`, `V3Phase1Tests` — PASS (V3 routing untouched by this change)
- `NativeTranscriptionTests` — PASS or SKIPPED depending on whether ONNX model is locally installed
- `FireRedTranscriptionServiceTests` — PASS or SKIPPED depending on FireRed install
- All NEW tests created in this plan — PASS

If anything fails: STOP. The task isn't complete.

### Task 22: Update CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add an entry under the unreleased section (or create a new one)**

Open `CHANGELOG.md`. The current top section is `[0.3.0] — 2026-04-25 (unreleased)`. Add to its `### Added` subsection:

```markdown
- **FireRed Chinese ASR backend** as a 4th engine option, plus an opt-in "Use FireRed for Chinese transcription" toggle visible under Cohere backends. Both routes share the same on-disk FireRed model files (`csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26`, ~1.24 GB).
  - **Quality:** in spike testing on SenseVoice's `asr_example_cn_en.wav` Chinese-English mixed sample, FireRed achieved 8.94% CER vs Cohere's 22.76% (zh prompt). FireRed preserves character-level fidelity including English code-switching ("做 machine learning 做 deep learning…"); Cohere paraphrases.
  - **Routing:** Toggle ON: V1 Chinese audio routes to FireRed; English and other languages stay on Cohere. FireRed backend: Chinese + English use FireRed; other languages auto-fallback to Cohere ONNX (also requires Cohere ONNX downloaded).
  - **V3 streaming unchanged:** sherpa-onnx FireRedASR2-AED has no streaming mode; V3 always uses Cohere regardless of toggle/backend.
  - **Bundling:** Adds vendored sherpa-onnx v1.12.40 macOS xcframework (~42 MB compressed in repo via Git LFS, links to existing `onnxruntime-swift-package-manager` — no duplicate ONNX runtime).
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): add FireRed Chinese ASR backend"
```

### Task 23: Manual UAT checklist

**Files:** none — manual verification.

- [ ] **Step 1: Verify each scenario from the spec's UAT section**

The spec's "Manual / UAT (post-implementation)" section lists 5 scenarios. Run each one against a built `.app` and capture the result. Failures → file as bugs and stop before tagging.

1. Existing Cohere user enables toggle, says "你好 测试一下"
   - Expected: download begins, completes; subsequent recording outputs FireRed-style text
2. Existing Cohere user enables toggle, says "Hello world"
   - Expected: outputs Cohere-style English text (no FireRed routing for `en` under toggle)
3. New user picks FireRed in onboarding
   - Expected: both Cohere ONNX + FireRed download (or surface a clear "Cohere ONNX also required" message); first Chinese utterance uses FireRed; first Japanese utterance uses Cohere ONNX as fallback
4. Cancel mid-FireRed download
   - Expected: state restored, toggle OFF, partial files removed
5. Disk filling up halfway through FireRed download
   - Expected: critical alert; partial cleanup confirmed

For scenario 3: if the "needs Cohere fallback" combined download flow is not yet implemented (the spec calls for a `CompositeDownload` wrapper but this plan defers it to a follow-up task — see Open Items), the current behavior is: the app refuses to commit `.fireRed` as active backend until Cohere ONNX is also present. That's acceptable for v1 — file the composite-download UI as a follow-up.

- [ ] **Step 2: Document UAT results**

If you find regressions, write up failures in a new commit with a `test(firered): UAT-flagged regressions` heading and STOP for review. Otherwise:

```bash
git commit --allow-empty -m "test(firered): UAT scenarios pass on local build"
```

---

## Open items deferred from this plan

- **`CompositeDownload` wrapper for FireRed-backend selection from a clean state.** The spec specifies sequential Cohere-ONNX → FireRed downloads with shared cancel. The plan currently relies on the user having Cohere ONNX already downloaded (the common case after onboarding). If there's user demand for fresh-install of FireRed-backend, file a follow-up: build a `Coalesced` two-step download that surfaces a single progress bar. Approximate effort: 1-2 days, ~150 LOC.
- **Intel Mac smoke test.** The xcframework declares `arm64,x86_64` support but the spike was on Apple Silicon only. Before tagging the release, build and smoke-test on an Intel Mac (or via Rosetta).
- **Toggle download flow polish.** The current `downloadFireRedFromToggle()` in SettingsView temporarily flips `activeBackend` to `.fireRed` to reuse `download()`. A cleaner alternative is to add `download(for: ModelBackend)` as an explicit overload. Refactor when the second consumer arrives.

---

## Self-Review

**Spec coverage:**

| Spec section | Plan task |
|---|---|
| `ModelBackend.fireRed` | Task 9-10 |
| `useFireRedForChinese` toggle | Task 11-12 |
| `FireRedTranscriptionService` | Task 6-8 |
| Routing function | Task 13-14 |
| Bundling sherpa-onnx (xcframework + modulemap + Swift wrapper) | Task 1-4 |
| Git LFS for static lib | Task 5 |
| onnxruntime coexistence | Task 1 step 3 (verification) + Task 4 step 2 (build) |
| Settings UI 4th row + sub-toggle | Task 17 |
| Onboarding 4th option | Task 18 |
| Error handling | Task 19-20 |
| Tests (unit + integration) | Tasks 7, 9, 11, 13, 19 |
| Regression suite | Task 21 |
| `CompositeDownload` for FireRed-backend clean install | Open Items (deferred) |

The spec's `CompositeDownload` is explicitly deferred — the plan calls this out in Open Items. All other spec sections have at least one task.

**Placeholder scan:** no "TBD", "TODO", or "fill in details" remain. Tasks 17 step 2 and 20 step 1 add real code, not placeholders.

**Type consistency:** `BackendChoice` has identical case names across Tasks 13, 14, 15. `setUseFireRedForChinese(_:)`, `committedUseFireRedChange`, `useFireRedForChinese` consistent across Tasks 11, 12, 16, 17. `routedTranscribeV1` referenced in Task 15 step 7 and Task 20 step 1, consistent.

**Scope:** 23 tasks across 10 phases. Each commit is independently reviewable. Estimated 3-5 days of focused work.
