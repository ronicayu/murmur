---
from: CR
to: EN
pri: P1
status: CHG:2
created: 2026-04-25
branch: feat/lid-whisper-tiny
refs: 092, 093, 094, 096, d77a594
---

## ctx

Round-2 verification of the LID fix commit d77a594 against all round-1 P0
findings (092 CR, 093 QA, 094 DA #3/#9). Eight of ten items are clean. Two
new concerns introduced by the fix pass.

---

## verify

| Finding | Verdict | Notes |
|---------|---------|-------|
| CR P0-1 Hann window | LGTM | `length` divisor confirmed at line 543. Only one call site (`buildHannWindow` via `lazy var window`); no other window application found. |
| CR P0-2 fatalError → throw | LGTM | `stftPower` is now `throws`; `extract` propagates `try`; `identify` propagates through `melExtractor.extract`; coordinator `do/catch` in `resolveTranscriptionLanguageAsync` handles it. Propagation chain is complete. |
| CR P0-3 convertError | CHG | See **New Concern #1** below. The check is present and correct, but a new issue was introduced. |
| CR P0-4 Toggle gate | LGTM | `.disabled(!modelManager.isAuxiliaryDownloaded(.lidWhisperTiny))` is bound to `@ObservedObject var modelManager`, so it is reactive to state changes. UserDefault reset fires in the `else if !lidReady, coordinator.lid != nil` branch — requires `lid` to be non-nil, so it does NOT fire on initial subscription when the model was never ready. Correct. |
| CR P0-5 silenceDetected ordering | LGTM | `catch MurmurError.silenceDetected` at line 909 precedes the generic `catch` at line 914. Order is correct. |
| DA #3 Badge consistency | CHG | See **New Concern #2** below. |
| DA #9 Unsupported Cohere language | LGTM | Verified: the `mapped == nil` path falls through to `return fallback` with no pill. Correct. |
| CR P1-2 Dead no-op | LGTM | `signal.withUnsafeBufferPointer { _ in }` removed. |
| QA P0-1 manifest truthy | LGTM | `test_auxiliaryManifestIsValid_returnsTrue_whenManifestAndSizesMatch` writes a real 8-byte file and a matching manifest; `auxiliaryManifestIsValid` is called on the result. Truthy path exercised with real file sizes, not a mock. |
| QA P0-2 modelPath nil/non-nil | LGTM | Two sub-tests, both using real temp directories. Sufficient. |
| QA P0-3 deleteAuxiliary | LGTM | Asserts filesystem removal AND state reset to `.notDownloaded`. Covers the chain QA required. |
| QA P0-4 refreshAuxiliaryState | LGTM | Both branches (ready/notDownloaded) exercised. |

---

## new concerns

**NC-1 (P1) — convertError reset between iterations.**
The `repeat/do-while` loop appends to `allSamples` and can `break` early
when `allSamples.count >= maxSamples`. In that case `status` may still be
`.haveData` and `convertError` may have been set on a *later* converter
call that was not the breaking iteration. The current check fires after the
loop exits regardless of exit path, which is correct. However, there is a
subtler issue: `convertError` is a single `NSError?` variable shared across
all loop iterations. If the converter sets it on iteration N and then
*clears* it on iteration N+1 (some converters reset the error pointer on
success), the check after the loop will miss the earlier failure.
AVAudioConverter's documented contract is that it only writes to the pointer
on error, not on success, so this is likely safe in practice — but the
assumption should be documented with a comment. Low operational risk; flag
for EN to confirm and add a one-line comment if agreed.

**NC-2 (P0) — Badge test does not verify pill render.**
`test_badgeUpdate_whenLIDOverridesIME_resolvedLanguageAndBadgeMatch` calls
`resolveTranscriptionLanguageAsync` and then asserts:
(a) the returned language code is `"zh"`, and
(b) `LanguageBadge.badgeText(resolvedCode: "zh", storedSetting: "auto")` equals `"ZH·"`.

Part (b) is a static helper call in the *test body* — it does not exercise
the `stopAndTranscribeV1` path where `activeBadge` is assigned and
`pill.show` is called. If someone removes or miswires the badge-update block
in `stopAndTranscribeV1` (lines 664–669), this test still passes. The DA #3
fix was specifically about the pill displaying the updated badge *during
transcription* — that call path is not covered by any test. The test should
either (a) spy on `pill.show` calls and assert a second call with the `ZH·`
badge, or (b) be renamed to
`test_resolvedLanguage_isLIDCode_whenConfidenceAboveThreshold` to
accurately describe what it actually asserts, with a comment noting that
the stopAndTranscribeV1 pill-update path is untested.

---

## out

**Not ready to push.** NC-2 is a P0: the test written to close DA #3 does
not cover the code that DA #3 required to be fixed. The badge-update block
in `stopAndTranscribeV1` has no test coverage at all. EN must either add a
`pill.show` spy assertion or honestly rename the test and accept the gap.
NC-1 is a P1 comment-only fix and can land in the same commit.
