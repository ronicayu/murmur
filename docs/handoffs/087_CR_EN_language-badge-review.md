---
from: CR
to: EN
pri: P1
status: CHG:2
created: 2026-04-20
---

## ctx

Code review of `feat/language-badge-on-pill` (commit `3907343`) against spec `085`. Two changes required before merge; everything else is clean.

## verdict

**CHG:2** — two real issues, both fixable without touching the architecture. No regressions found.

---

## findings

### 1. Must Fix — V3 streaming: badge-free first frame is a spec violation

**Severity:** 🔴 Must Fix

**Where:** `Murmur/AppCoordinator.swift`, `startStreamingRecordingFlow()`, the `pill.show` at line ~415 (before `resolveTranscriptionLanguage()` is called).

```swift
// Current — fires with nil badge:
pill.show(state: .streaming(chunkCount: 0), audioLevel: 0)

audioLevelTask = Task { @MainActor [weak self] in ... }

try await withTimeout(seconds: 5, operation: "start recording") {
    try await self.audio.startRecording()
}

// ... then badge is resolved here, after the await
let lang = resolveTranscriptionLanguage()
activeBadge = LanguageBadge.badgeText(...)
pill.show(state: .streaming(chunkCount: 0), ..., languageBadge: activeBadge)
```

The spec says: "Show the badge for the **full duration** of the recording state." The initial frame of `.streaming(chunkCount: 0)` is a recording state. For however long `startRecording()` takes (up to 5 s in the worst case), the pill is visible with no badge. EN noted this in the handoff as "correct — the language isn't known until that point" — that framing is not right. `resolveTranscriptionLanguage()` is synchronous and reads from UserDefaults + `TISCopyCurrentKeyboardInputSource()`; it does not require the audio session to be open. It can be called before `audio.startRecording()`.

**Fix:** Move the badge resolution block up to before the initial `pill.show`, exactly as V1 does. There is no spec constraint violated by this — the spec only forbids refactoring `resolveTranscriptionLanguage()` itself, not reordering its call site within the streaming flow.

```swift
private func startStreamingRecordingFlow() async {
    do {
        // Resolve badge before showing pill — mirrors V1 flow
        let lang = resolveTranscriptionLanguage()
        let storedSetting = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
        activeBadge = LanguageBadge.badgeText(resolvedCode: lang, storedSetting: storedSetting)

        transition(to: .recording)
        audioFeedback.playStartRecording()
        pill.show(state: .streaming(chunkCount: 0), audioLevel: 0, languageBadge: activeBadge)

        audioLevelTask = Task { @MainActor [weak self] in ... }

        try await withTimeout(seconds: 5, operation: "start recording") {
            try await self.audio.startRecording()
        }

        // lang already resolved above — reuse it
        let startOffset = resolveCurrentCursorOffset()
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        // remove the duplicate resolveTranscriptionLanguage() call and storedSetting block here
        let wavURL = ...
```

The second `pill.show` with badge (the "badge-bearing refresh" EN described) can be removed; it no longer serves a purpose. The duplicate `resolveTranscriptionLanguage()` call near line 435 also disappears.

---

### 2. Must Fix — `UserDefaults` key hardcoded twice in AppCoordinator, diverged from resolution function

**Severity:** 🔴 Must Fix (latent bug / maintainability)

**Where:** `Murmur/AppCoordinator.swift` lines ~366 and ~436.

```swift
let storedSetting = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
```

`resolveTranscriptionLanguage()` already reads this same key (line 848). Now there are three copies of the string literal `"transcriptionLanguage"` in AppCoordinator alone, plus the two call sites added here. If the key is ever renamed (or if the default changes from `"auto"`), these will drift silently.

The spec already says "Auto-mode detection = the user's stored `transcriptionLanguage` UserDefault equals `"auto"`. Do not infer it from anything else." — the right place to enforce that contract is in `badgeText`, and `badgeText` already does it correctly. The problem is that AppCoordinator is fetching UserDefaults a second time instead of calling `resolveTranscriptionLanguage()` once and letting `badgeText` re-read from defaults for the `isAuto` determination.

However, because `badgeText` already reads `storedSetting` as a parameter rather than reading UserDefaults directly, the simplest fix is to extract the key into a constant. A private static or a simple inline constant at the top of `startV1RecordingFlow` / `startStreamingRecordingFlow` is fine:

```swift
// AppCoordinator.swift — add near other private constants, or inline at call site
private static let transcriptionLanguageKey = "transcriptionLanguage"

// Then at both call sites:
let storedSetting = UserDefaults.standard.string(forKey: Self.transcriptionLanguageKey) ?? "auto"
```

Alternatively (slightly cleaner), extract a private helper that returns both values together — but that is a larger change and likely overkill for this spec. The constant extraction is the minimum required.

---

### 3. Should Fix — `languageBadge` declared `var` with default on `FloatingPillView`; should be `let`

**Severity:** 🟡 Should Fix

**Where:** `Murmur/Views/FloatingPillView.swift` line 6.

```swift
var languageBadge: String? = nil
```

`FloatingPillView` is a value type with all other stored properties as `let`. This `var` is inconsistent and creates the false impression that callers might mutate it after construction (they don't — `FloatingPillController.show()` constructs a new view each frame). The default value for backward-compat is correct and should be kept; just change `var` to `let`:

```swift
let languageBadge: String? = nil
```

Swift allows `let` with a default value on a struct member — SwiftUI uses this pattern throughout.

---

### 4. Nit — MARK comment `// MARK: - BadgeView` doesn't match Swift naming convention used elsewhere

**Severity:** 🟢 Nit

**Where:** `Murmur/Views/LanguageBadge.swift` line 35.

Other MARK headers in the codebase use the type name exactly (e.g., `// MARK: - LanguageBadge`). `BadgeView` is the informal name, not the type. Suggest `// MARK: - LanguageBadgeView` for consistency and searchability.

---

## what's good

- **`LanguageBadge` enum shape is correct.** Using an enum as a pure-static namespace for formatter functions is idiomatic Swift. The two-function API (`format` + `badgeText`) is the right layering: `format` is the primitive (testable in isolation), `badgeText` is the coordination point. Good separation.
- **`isRecordingState` guard in the view is correct.** Pattern-matching `case .recording, .streaming` works correctly for `streaming(chunkCount: Int)` associated-value case — Swift pattern matching on the case label without binding the value is valid. No bug here.
- **Concurrency is sound.** `AppCoordinator` is `@MainActor`-isolated (line 53). Both `activeBadge` reads and writes happen on the main actor — the audio-level task closures are explicitly `Task { @MainActor [weak self] in ... }`. No data race.
- **`activeBadge` lifetime is correct.** Storing it as an instance property so the async audio-level task closure can capture `self` (not a copy of the badge at Task-creation time) is the right call. Cleared on next recording start. No new UserDefaults key. Clean.
- **`ZStack(.topTrailing)` overlay is layout-safe.** The inner `HStack` is fully padded and constrained before the ZStack is composed. Badge floats over the pill without perturbing the HStack geometry. No layout shift.
- **Test coverage is solid for the pure logic.** All 14 codes exercised. Fixed/auto/unknown for both `format` and `badgeText`. The `??·` edge case (unknown code in auto mode) is covered.
- **Diff is small.** Spec asked for one view addition + one propagated value. That's exactly what this is.

---

## summary

Two required changes: (1) move badge resolution before the initial `.streaming` `pill.show` in V3 — the current code leaves the badge absent for the duration of `startRecording()`; (2) extract the `"transcriptionLanguage"` key literal to a constant — it now appears three times across the resolution function and the two new call sites. One style change (`var` → `let` on the view param). One nit. Architecture, concurrency, formatter design, and test coverage are all in good shape.

## out

Awaiting EN fixes on items 1 and 2. Item 3 recommended before merge. Item 4 at EN's discretion.
