---
from: CR
to: EN
pri: P1
status: CHG:5
created: 2026-04-25
branch: feat/lid-whisper-tiny
refs: 091
---

## ctx

Review of the Whisper-tiny LID feature on `feat/lid-whisper-tiny`. The architecture is sound — actor isolation, protocol-behind-the-slot, clean fallthrough on every error path — and the coordinator integration is exactly right. Three issues need attention before merge: one DSP correctness bug that will quietly hurt LID quality on the last frame of every window, one crashing `fatalError` that must become a thrown error, one unread `convertError` that silently swallows audio-converter failures. Two P1 settings/UX gaps round out the must-fix list. Everything else is advisory.

## findings

### P0 — must fix before merge

**P0-1. Periodic vs. symmetric Hann window — wrong formula**
`LanguageIdentificationService.swift`, `buildHannWindow`, line 537.

```swift
w[i] = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(length - 1)))
```

This is a symmetric (DFT-even) Hann window. Whisper uses `numpy.hann(N)`, which is a *periodic* window:

```swift
w[i] = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(length)))
//                                                          ^^^^^^^^^
//                                                          length, not length - 1
```

The only visible difference is that `w[N-1]` is `6e-5` (periodic) instead of `0.0` (symmetric). The practical accuracy impact on LID is small but this is an off-spec deviation vs. the model's training preprocessing — any future regression or accuracy audit will be confused by it. Fix is a one-character change.

**P0-2. `fatalError` in hot path — crash on OOM or platform limitation**
`LanguageIdentificationService.swift`, `stftPower`, lines 412–413.

```swift
guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
    fatalError("WhisperMelExtractor: vDSP_create_fftsetup failed")
}
```

`vDSP_create_fftsetup` returns nil on out-of-memory or if the requested `log2n` exceeds the platform maximum. The LID contract is "never fatal to transcription." Replace with a thrown error so the caller's `do/catch` in `resolveTranscriptionLanguageAsync` handles it:

```swift
guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
    throw MurmurError.transcriptionFailed("LID vDSP_create_fftsetup failed (log2n=\(log2n))")
}
```

`extract(samples:)` and its callers in `identify` are already `throws`, so the propagation is free.

**P0-3. `convertError` declared, never checked**
`LanguageIdentificationService.swift`, `loadProbeSamples`, lines 216 and 237.

```swift
var convertError: NSError?
// ...
status = converter.convert(to: chunkBuffer, error: &convertError, withInputFrom: inputBlock)
```

`convertError` is written by the converter but never read. If the converter fails with a non-fatal status (e.g., a corrupt input frame) the error is silently swallowed and `allSamples` may be shorter than expected, causing the mel extractor to pad aggressively. Add a check after the loop:

```swift
} while status == .haveData

if let err = convertError {
    throw MurmurError.transcriptionFailed("LID audio conversion error: \(err.localizedDescription)")
}
```

**P0-4. Toggle remains enabled after model deletion — no gate on coordinator side**
`SettingsView.swift`, lines 122–130; `AppCoordinator.swift`, lines 880–889.

The `autoDetectLanguage` toggle has no `disabled()` modifier based on whether the model is installed. A user can: enable the toggle, download the model, delete the model from the Model tab, and the toggle stays `true`. The next transcription will hit the `guard let lid else` branch and flash "Language model not installed" on every recording until the user notices and re-enables. This is not a subtle edge — it is the delete happy path.

Two-part fix:
1. In `SettingsView`, disable the toggle when the model is not installed:
```swift
Toggle("", isOn: $autoDetectLanguage)
    .disabled(!modelManager.isAuxiliaryDownloaded(.lidWhisperTiny))
```
2. In `MurmurApp.$auxiliaryStates` subscriber, when `!lidReady`, also reset the UserDefault:
```swift
} else if !lidReady, coordinator.lid != nil {
    coordinator.lid = nil
    UserDefaults.standard.set(false, forKey: "autoDetectLanguage")
}
```
Without (2), the pill error fires on every subsequent recording even after the settings window is closed.

**P0-5. `silenceDetected` error surfaces user-facing pill in coordinator catch block**
`LanguageIdentificationService.swift`, line 143; `AppCoordinator.swift`, lines 901–908.

`identify` throws `MurmurError.silenceDetected` when `samples.isEmpty`. The coordinator's blanket `catch` block turns this into a "Language detection unavailable" pill. But silence is a normal condition (the user pressed hotkey by accident, nothing was said). The correct behavior is silent fallback, not an error pill. Either:

- Return a sentinel `LIDResult(code: "", confidence: 0)` instead of throwing, so the caller falls through to `fallback` at the confidence-threshold check, or
- Catch `.silenceDetected` specifically before the generic catch:

```swift
} catch MurmurError.silenceDetected {
    Self.log.info("LID: silent audio, using fallback=\(fallback, privacy: .public)")
    return fallback
} catch {
    // ... existing pill error for genuine inference failures
}
```

### P1 — should fix

**P1-1. Reflect-pad produces 3001 frames; truncation silently discards a frame**
`LanguageIdentificationService.swift`, `stftPower`, lines 405–467.

With `nFFT=400, hop=160`, padding *both* sides by `nFFT/2=200` and then computing `(padded - nFFT) / hop + 1` gives **3001** frames for a 480,000-sample input. The frame-fixup at lines 460–468 silently truncates to 3000. The reference (HF `WhisperFeatureExtractor` / `librosa center=True`) produces exactly 3000 frames via `ceil(n_samples / hop_length)`. Numerically the truncated frame is all-silence (it would be the rightmost reflection of the last few samples), so LID accuracy is not meaningfully affected. But the deviation is worth documenting with a comment explaining why 3001→3000 truncation is intentional and safe, so the next engineer doesn't "fix" it by removing the truncation and changing the encoder input shape.

**P1-2. Dead no-op inside the frame loop**
`LanguageIdentificationService.swift`, line 423.

```swift
signal.withUnsafeBufferPointer { _ in }
```

This call does nothing — it opens and immediately discards the unsafe pointer. It looks like a leftover from a refactor. Remove it.

**P1-3. fp16 logits path has no test**
`LanguageIdentificationService.swift`, `float16ToFloat32`, lines 326–345.

The handoff calls this out as "implemented but not exercised." The vImage path is short and the logic is correct, but a model swap from `onnx-community/whisper-tiny` to a non-quantised or differently-exported variant could emit fp16 and hit this code path. At minimum, add a unit test in `LanguageIdentificationTests.swift` that round-trips a small known fp16 buffer through `readLastLogitRow` and verifies the float32 values. This does not require real ONNX sessions — the conversion helper is private to the actor but can be factored out or the test can exercise it indirectly through a mock logits tensor if the harness supports it. Mark it as a QA ask if it requires integration scaffolding.

**P1-4. `autoDetectLanguage` UserDefault key is a stringly-typed string duplicated across three files**
`AppCoordinator.swift` line 866, `SettingsView.swift` line 12, `LanguageIdentificationTests.swift` lines 98, 107, etc.

The key `"autoDetectLanguage"` appears six times across the codebase as bare string literals. A single rename will silently break the feature (existing users' setting becomes invisible). Extract to a static constant, e.g. `AppCoordinator.autoDetectLanguageKey`, matching the existing pattern for `transcriptionLanguageKey` on line 135.

### P2 — nice to have

**P2-1. Download-on-toggle fires `try?` and discards the error**
`SettingsView.swift`, line 128.

```swift
Task { try? await modelManager.downloadAuxiliary(.lidWhisperTiny) }
```

If `downloadAuxiliary` throws (disk full, network error), the error is silently swallowed. `modelManager.auxiliaryStates` will be updated to `.error(...)` so the model-row UI does surface the failure — but only if the user switches to the Model tab. The pattern used elsewhere (primary model row) at least shows an inline error in the same row. Harmless for now since the download guard already populates `auxiliaryStatusMessage`, but worth a comment explaining the silent `try?` is intentional because state is surfaced via `auxiliaryStates`.

**P2-2. `melExtractor` is a `let` stored property on the actor; `lazy var` filterbank/window inside a `final class` is Sendable-safe, but the non-isolation of `WhisperMelExtractor` should be documented**
`LanguageIdentificationService.swift`, line 82.

`WhisperMelExtractor` is `final class` (not `Sendable`), stored as `let` on the actor. Because it is accessed only from within the actor's isolation domain, this is correct and safe. But the compiler cannot verify the safety — the lack of a conformance annotation means a future refactor that accesses `melExtractor` from outside the actor will compile without error and introduce a race. Either mark `WhisperMelExtractor` as `@unchecked Sendable` with a comment explaining why (all mutation is during lazy init, subsequent use is read-only), or make `melExtractor` an actor property so the conformance requirement is checked. The current code is correct; this is a documentation/future-safety nit.

**P2-3. `preload()` can be called concurrently before `loaded` is set to true**
`LanguageIdentificationService.swift`, lines 106–126.

```swift
func preload() async throws {
    guard !loaded else { return }
    // ... async work
    loaded = true
}
```

Actor isolation serializes callers, so re-entrancy within a single actor hop cannot happen. However, `identify()` calls `preload()` with `try await` on line 136, and the actor can suspend between the `guard !loaded` check and `loaded = true`. A second call to `identify()` arriving at the suspension point would both proceed past the guard and attempt to create two `ORTSession` pairs, leaking the first pair. The fix is a separate `loading: Bool` flag set before the `await` work begins:

```swift
private var loaded = false
private var loading = false

func preload() async throws {
    guard !loaded, !loading else { return }
    loading = true
    defer { loading = false }
    // ... existing work
    loaded = true
}
```

This is low-severity in practice since `identify` is called sequentially per recording and `preload` completes in milliseconds, but it is a latent race.

## answers to open questions

**1. `AuxiliaryModel` parallel hierarchy vs. sub-state of `ModelBackend` — right shape?**

Yes, the parallel hierarchy is right. `ModelBackend` carries the notion of "exactly one is active"; aux models have no such mutual exclusivity. Folding LID into `ModelBackend` would force every backend switch to carry LID awareness it doesn't own, and would make the second aux model (post-transcription cleanup) awkward. The `CaseIterable` enumeration plus per-key dicts in ModelManager is the correct abstraction. The only concern is that `AuxiliaryModel.allCases` drives a `for` loop in the constructor — when a second case is added, that loop picks it up automatically, which is the right default.

**2. Confidence threshold 0.60 as `private static` vs. UserDefault/advanced Settings?**

Keep it as `private static` for now. The threshold needs tuning from real `.public` log data that does not yet exist — promoting it to a user-visible knob before it has a validated range teaches users to tweak a dial with no calibration reference. Once you have a week of dogfood logs and a distribution of per-language confidence scores, promote it to an advanced setting or a per-language table. The code comment ("Tunable from real-world logs — see .public LID log lines") is exactly the right intent; just execute on it before exposing it to users.

**3. Pill error "Language detection unavailable" on LID failure — too noisy?**

Too noisy for genuine inference failures; *wrong* for silence errors (see P0-5 above). For genuine inference failures (ONNX throws, corrupted audio), the error pill is appropriate on the *first* failure but annoying if it fires on every single recording thereafter. The right split:
- Silence (`silenceDetected`) → silent fallback, no pill.
- First ONNX/inference failure → show pill, log at `.error`.
- Subsequent failures within the same session → log only, no repeated pill.

A simple `private var lidHasFailed = false` flag on the coordinator, reset on successful identify, achieves this without complexity.

**4. Ship `WhisperMelExtractor` without a librosa fixture comparison test, or block?**

Do not block the merge on a full librosa fixture test — that is an integration test and belongs in QA's suite (see `093_QA_EN_lid-coverage.md`). But add at minimum: (a) the Hann window fix from P0-1, and (b) a unit test for `float16ToFloat32` (P1-3) before merge. The normalisation logic (`logAndNormalise`) is correct against the reference spec as reviewed. The reflect-pad frame-count discrepancy (P1-1) should be documented with a comment rather than blocked on.

## out

CHG:5. The five P0 issues are all small fixes — none require architectural change. The Hann window bug and the `fatalError` are the ones to get right; the other three are defensive correctness. P1 items are recommended for this PR but not blockers if EN wants a fast follow. P2 items can be deferred.

Specific items for EN to address before re-review:
1. `buildHannWindow`: divide by `length`, not `length - 1`.
2. `vDSP_create_fftsetup` nil branch: throw instead of `fatalError`.
3. `convertError`: read and throw after the converter loop.
4. Toggle disabled state + UserDefault reset on model deletion.
5. Catch `silenceDetected` separately, no pill, silent fallback.
