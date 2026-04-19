---
from: QA
to: EN, PM
pri: P1
status: CHG:2
created: 2026-04-20
---

## ctx

Coverage review and manual UAT plan for the language-badge feature on `feat/language-badge-on-pill` (commit `3907343`). Spec: `085_PM_EN_language-badge-spec.md`. Implementation handoff: `086_EN_CR_QA_language-badge-impl.md`.

---

## Part A — Automated test coverage

### What the 9 tests cover

`LanguageBadgeTests` tests the pure formatter logic in full:
- `format(code:isAuto:)` — fixed known, auto known, unknown code (fixed), unknown code (auto): covered.
- All 14 supported codes recognized (not `??`): covered via `test_format_allSupportedCodesAreRecognized`.
- `badgeText(resolvedCode:storedSetting:)` — fixed, auto/EN, auto/ZH, auto/unknown: covered.

The formatter unit is well-tested. 9 tests for ~20 LOC of pure logic is adequate; no expansion needed there.

### Gap 1 — `isRecordingState` guard is untested (CHG request)

`FloatingPillView.isRecordingState` is a computed property that gates whether the badge renders. It returns `true` only for `.recording` and `.streaming`; all other states return `false`. This is the central "badge disappears after stop" behavior (success criterion 5).

There is no test that:
- passes a badge string + `.recording` state → badge should be non-nil/rendered, and
- passes a badge string + `.error` / `.transcribing` / `.undoable` state → badge should be suppressed.

This is testable today without UI: `FloatingPillView` is a `@testable import Murmur` struct. The property is `private`, but the observable behavior is that in non-recording states the view renders no `LanguageBadgeView`, which can be verified by rendering `FloatingPillView` in an `NSHostingView` in a test and inspecting the view tree — or more simply, by making `isRecordingState` `internal` and testing it directly.

**Recommended test (add to `LanguageBadgeTests.swift`):**

```swift
// MARK: - FloatingPillView.isRecordingState guard

func test_isRecordingState_trueForRecordingAndStreaming() {
    // Verify the states that should show the badge
    let recordingView = FloatingPillView(state: .recording, audioLevel: 0, languageBadge: "EN")
    let streamingView = FloatingPillView(state: .streaming(chunkCount: 3), audioLevel: 0, languageBadge: "ZH·")
    XCTAssertTrue(recordingView.isRecordingState)
    XCTAssertTrue(streamingView.isRecordingState)
}

func test_isRecordingState_falseForNonRecordingStates() {
    // Badge must be suppressed in all non-recording states
    let states: [AppState] = [
        .idle,
        .transcribing,
        .injecting,
        .undoable(text: "hi", method: .clipboard),
        .error(.silenceDetected),
    ]
    for state in states {
        let view = FloatingPillView(state: state, audioLevel: 0, languageBadge: "EN")
        XCTAssertFalse(view.isRecordingState, "Expected isRecordingState == false for state \(state)")
    }
}
```

Note: `isRecordingState` is currently `private`. Change it to `internal` (or add an `@testable` accessor) to make this testable. This is a one-word change with no behavioral impact.

### Gap 2 — V3 streaming: badge set after timeout, before audio tasks (CHG request)

EN's implementation note states: "the initial `pill.show` before `resolveTranscriptionLanguage()` runs shows no badge; the badge-bearing refresh fires immediately after resolution." This means V3 has a window where the pill is visible but the badge is absent. The transition from nil→badge should happen fast enough to be imperceptible, but it is architectural behavior worth pinning.

There is no test that verifies `startStreamingRecordingFlow` sets `activeBadge` before the audio-level task closures can fire the first badge-bearing update. This requires an `AppCoordinator` integration test with a stub audio/streaming service — the same harness already exists in `UATFixTests.swift` (see `P0VoiceInputPauseTests`).

**Recommended test (add to `AppCoordinatorTests.swift` or a new `LanguageBadgeIntegrationTests.swift`):**

```swift
// Verify that activeBadge is non-nil after startStreamingRecordingFlow begins
// (requires a stub StreamingTranscriptionCoordinator that stalls after lang resolution)
// This is a medium-effort test; flag as follow-up if the stub infrastructure is not ready.
```

This is lower priority than Gap 1 — the code path is straightforward and the race window is tiny — but it is the one realistic regression scenario for V3 badge behavior. Flag as a follow-up if stub infrastructure is not available.

### Brittleness notes

- `test_format_allSupportedCodesAreRecognized` hard-codes the 14-code list inline. If `ONNXTranscriptionBackend` gains or loses codes, the test will diverge from the implementation. Not urgent, but worth noting: the test could import `LanguageBadge.supportedCodes` directly (if made `internal`) to stay in sync automatically.
- No flaky tests observed. All 9 tests are pure-function, synchronous, and deterministic.

### Summary verdict

Coverage of the formatter: **complete**. Coverage of the view-layer guard and the V3 propagation path: **missing**. The formatter is the higher-value logic, so the 9 existing tests are a solid foundation. Gap 1 (the `isRecordingState` guard) is the only gap that could plausibly let a regression through silently and should be addressed before merge. Gap 2 (V3 streaming timing) is a follow-up.

**Status: CHG:2** — two items flagged back to EN before this can be marked LGTM on coverage.

---

## Part B — Manual UAT test plan

**Preconditions:**
- Merge `feat/language-badge-on-pill` and build/run the app (Debug or Release).
- Microphone permission granted.
- The app's status bar icon is visible.
- Estimated time: 5–8 minutes.

---

### Setup

1. Open **System Settings > Keyboard > Input Sources**. Confirm you have at minimum two input sources installed: one for U.S. English and one for a non-Latin script (Pinyin – Simplified is recommended). If Pinyin is not installed, add it now via the `+` button.
2. In **Murmur Settings** (click the menu bar icon > gear icon), locate the **Language** picker. Confirm it is set to **Auto** to start.

---

### Test 1 — Fixed English badge

**Setup:** Settings > Language = `English`

| Step | Action | Expected |
|------|--------|----------|
| 1.1 | Set Language to `English` in Murmur Settings | — |
| 1.2 | Press the V1 push-to-talk hotkey and hold | Floating pill appears |
| 1.3 | Observe the top-right corner of the pill | Badge reads `EN` (no dot, no suffix) |
| 1.4 | Release the hotkey | Pill transitions to success/error state |
| 1.5 | Observe the top-right corner of the pill | Badge is **absent** |

Pass: step 1.3 shows `EN`, step 1.5 shows no badge.

---

### Test 2 — Fixed Chinese badge

**Setup:** Settings > Language = `Chinese (Simplified)`

| Step | Action | Expected |
|------|--------|----------|
| 2.1 | Set Language to `Chinese (Simplified)` in Murmur Settings | — |
| 2.2 | Press V1 hotkey and hold | Pill appears |
| 2.3 | Observe badge | Badge reads `ZH` |
| 2.4 | Release hotkey | Pill transitions away from recording state |
| 2.5 | Observe pill | Badge absent |

Pass: `ZH` shown, no dot.

---

### Test 3 — Auto mode, U.S. English input source

**Setup:** Settings > Language = `Auto`; macOS active input source = U.S. English

| Step | Action | Expected |
|------|--------|----------|
| 3.1 | Set Language to `Auto` | — |
| 3.2 | Switch macOS input source to **U.S.** using ⌃Space (or the Input Sources menu in the menu bar) | Menu bar input indicator shows U.S. |
| 3.3 | Press V1 hotkey and hold | Pill appears |
| 3.4 | Observe badge | Badge reads `EN·` (EN + middle dot U+00B7, not a period) |
| 3.5 | Release | Badge disappears |

Pass: `EN·` shown.

---

### Test 4 — Auto mode, Pinyin input source

**Setup:** Settings > Language = `Auto`; macOS active input source = Pinyin – Simplified

| Step | Action | Expected |
|------|--------|----------|
| 4.1 | Settings > Language remains `Auto` | — |
| 4.2 | Switch macOS input source to **Pinyin – Simplified** via ⌃Space | Menu bar shows Pinyin indicator |
| 4.3 | Press V1 hotkey and hold | Pill appears |
| 4.4 | Observe badge | Badge reads `ZH·` |
| 4.5 | Release | Badge disappears |

Pass: `ZH·` shown.

---

### Test 5 — Badge absent in success/error states

This is partially covered by the release step in Tests 1–4, but verify explicitly:

| Step | Action | Expected |
|------|--------|----------|
| 5.1 | Set Language to `English`, press hotkey, hold for 1–2 seconds, release | Transcription runs |
| 5.2 | As pill shows success/undoable state (green checkmark), observe top-right | No badge |
| 5.3 | Press Escape during a recording to trigger cancel/error state | Pill shows error/dismissed state |
| 5.4 | Observe top-right | No badge |

Pass: badge not visible in any post-recording state.

---

### Test 6 — V3 streaming mode

**Setup:** Settings > enable V3 streaming (if behind a toggle) or confirm V3 is the active recording mode.

| Step | Action | Expected |
|------|--------|----------|
| 6.1 | Set Language to `English` | — |
| 6.2 | Trigger V3 streaming recording | Pill shows streaming waveform icon |
| 6.3 | Observe badge during active streaming | Badge reads `EN` |
| 6.4 | Set Language to `Auto`, switch input source to U.S., trigger V3 streaming | Badge reads `EN·` |
| 6.5 | End streaming | Badge disappears |

Pass: badge behavior identical to V1 in both fixed and auto modes.

---

### Edge case A — Switch input source between recordings (not in spec)

| Step | Action | Expected |
|------|--------|----------|
| A.1 | Language = `Auto`, input source = U.S. English. Start/stop one recording. Confirm badge was `EN·`. | — |
| A.2 | Without relaunching: switch input source to Pinyin. Start a new recording. | Badge reads `ZH·` |

Pass: badge reflects the input source active **at recording start**, not from the previous recording.

---

### Edge case B — Switch from Auto to Fixed between recordings (not in spec)

| Step | Action | Expected |
|------|--------|----------|
| B.1 | Language = `Auto`, input source = Pinyin. Start recording. Confirm `ZH·`. Stop. | — |
| B.2 | Change Language to `English`. Start recording. | Badge reads `EN` (no dot) |
| B.3 | Change Language back to `Auto`. Start recording. | Badge reads `ZH·` again (dot restored) |

Pass: switching fixed/auto and back correctly affects dot presence.

---

### Edge case C — Visual check: badge does not compete with audio meter

No pass/fail threshold — subjective check.

| Step | Action | Expected |
|------|--------|----------|
| C.1 | During a V1 recording, observe the pill with varying audio levels (speak loudly) | The audio level circle in the pill expands; the badge remains visually readable and does not overlap with the circle or text |

Pass: badge is readable, low-contrast, positioned in the top-right corner without layout shift.

---

### Pass/fail summary

| # | Criterion | Source |
|---|-----------|--------|
| 1 | Fixed EN → `EN` | Spec SC1 |
| 2 | Fixed ZH → `ZH` | Spec SC2 |
| 3 | Auto + US English → `EN·` | Spec SC3 |
| 4 | Auto + Pinyin → `ZH·` | Spec SC4 |
| 5 | Post-recording states → no badge | Spec SC5 |
| 6 | V3 streaming → same behavior | Spec SC6 |
| A | Input source switch between recordings | Edge case |
| B | Fixed/Auto toggle round-trip | Edge case |
| C | Visual non-competition with audio meter | Edge case |

Total: **6 spec criteria + 3 edge cases = 9 UAT checks**.

---

## out

**Verdict:** `CHG:2` — 9 unit tests cover the formatter completely; 2 test gaps need addressing before merge:
1. `isRecordingState` guard on `FloatingPillView` is not covered. EN to make the property `internal` and add 2 tests.
2. V3 streaming badge-before-audio-task timing is unverified. Flag as follow-up if AppCoordinator stub infrastructure is not ready.

Manual UAT: 9 checks (6 spec + 3 edge), runnable in 5–8 minutes.
