---
from: EN
to: CR
pri: P1
status: RDY
created: 2026-04-19
branch: fix/fu-01-download-ui-polish
commits:
  - 1c07b9e  feat(ModelManager): expose downloadedBytes for cancel-confirm dialog
  - 25c66db  feat(FU-01): add 'Locked during download' caption + tooltip to engine rows
refs: 074, 076
---

## ctx

Three UX polish items from UT 074, scoped to FU-01 per PM 076 ship decision.
Branch `fix/fu-01-download-ui-polish` off main at v0.2.1.

## changes

### 1. Disabled engine row — locked caption + tooltip (P1)

**Copy chosen:** `"Locked during download"` (inline caption) and
`"Locked during download — wait for it to finish or cancel first."` (tooltip).

Tone rationale: matches the neutral, lowercase-first style of existing
captions in both views (e.g. `"Download: ~1.5 GB"`, `"Model downloaded"`).
No exclamations, no blame.

**SettingsView.swift — `engineRow(_:)`**
- Line ~316: extracted `isLocked: Bool = switchLocked && !isActive` local.
- Line ~328: conditional `Text("Locked during download")` in `.caption` /
  `Color.secondary`, inside the `VStack`, shown only when `isLocked`. No
  reserved vertical space when unlocked.
- Line ~341: `.disabled(isLocked)` (unchanged behavior, now uses the local).
- Line ~342: `.help(isLocked ? "Locked during download — ..." : "")`.

**OnboardingView.swift — `backendCard(_:)` + `backendCardContent(_:isDownloaded:isLocked:)`**
- `backendCard` line ~533: extracted `isLocked` local; passes it to
  `backendCardContent`.
- `backendCard` line ~553: `.disabled(isLocked)`.
- `backendCard` line ~554: `.help(isLocked ? "..." : "")`.
- `backendCardContent` signature extended with `isLocked: Bool` parameter.
- `backendCardContent` line ~592: same conditional caption as SettingsView.

### 2. Confirmation dialog before cancelling large in-flight download (P1)

**Threshold:** `100 * 1_000_000` bytes (100 MB). Declared as
`private static let cancelConfirmThresholdBytes: Int64` in both
`SettingsView` and `OnboardingView`. Below the threshold, one click cancels
directly — very little data would be discarded. At or above, the dialog
fires.

**Data source for MB count:** new `@Published private(set) var downloadedBytes: Int64`
added to `ModelManager` (commit 1c07b9e). The download monitor loop (which
already tracked `modelSize` for the status message) now also writes
`self.downloadedBytes = modelSize` each polling cycle. Reset to `0` in
`cancelDownload()` and `refreshState()`.

**Copy chosen:**
- Dialog title: `"Cancel Download?"`
- Message: `"You've downloaded \(mb) MB — cancelling will discard it."`
- Destructive button: `"Cancel Download"`
- Default/cancel button: `"Keep Downloading"`

**SettingsView.swift**
- Line ~19: `@State private var showCancelDownloadConfirmation = false`
- Line ~23: threshold constant
- Lines ~240–258: Cancel Download button now conditionally sets
  `showCancelDownloadConfirmation = true` when above threshold; `.confirmationDialog`
  modifier attached to the button.

**OnboardingView.swift**
- Line ~17: `@State private var showCancelDownloadConfirmation = false`
- Line ~21: threshold constant (mirrors SettingsView; comment notes to keep in sync)
- Lines ~331–352: same pattern — button sets flag when above threshold;
  `.confirmationDialog` attached to the button.

No shared state object was created for the dialog — the dialog is a single
`@State` bool in each view, which is idiomatic SwiftUI and avoids coupling
the two views through a shared object. The threshold constant is duplicated
with a comment; if it diverges later a follow-up can centralize it.

### 3. Copy consistency — "Cancel" → "Cancel Download" (P2)

**OnboardingView.swift** `modelDownloadStep`, line ~332:
Changed button label from `"Cancel"` to `"Cancel Download"`. Both surfaces
now use `"Cancel Download"` consistently.

No other label changes made — other copy was already consistent or out of
scope (heading text, status badge labels are intentionally context-specific).

## ModelManager changes (commit 1c07b9e)

- `Murmur/Services/ModelManager.swift` line ~154:
  `@Published private(set) var downloadedBytes: Int64 = 0`
- Monitor loop `~line 524`: `self.downloadedBytes = modelSize`
- `cancelDownload()` `~line 691`: `downloadedBytes = 0`
- `refreshState()` `~line 413` and `~line 419`: `downloadedBytes = 0` in
  both branches

## test results

Targeted filter:
```
swift test --filter "B3B4|SetActiveBackend|CancelDownload|IsModelDownloaded|OnboardingViewModelRepublish|ManifestVerification"
```
→ 25 tests, 0 failures, 2 skipped

Full suite:
```
swift test
```
→ 293 tests, 9 failures — all 9 are pre-existing `V3AXSelectReplaceTests`
failures (accessibility integration tests that require a live focused text
field; tracked FU-10). 0 new failures.

## reinstall

```
pkill -9 -f "Murmur.app/Contents/MacOS/Murmur" 2>/dev/null; true
bash Scripts/build-release.sh   # → Build complete! (7.20s)
rm -rf /Applications/Murmur.app
cp -R dist/Murmur.app /Applications/Murmur.app
xattr -dr com.apple.quarantine /Applications/Murmur.app
defaults read /Applications/Murmur.app/Contents/Info.plist CFBundleShortVersionString
# → 0.2.1
```

## scope

FU-02 (ETA / byte totals), FU-07 (stall timeout) not touched. Changes are
strictly limited to the three FU-01 items.

## ask to CR

Review the two commits above:
1. `downloadedBytes` addition to ModelManager — confirm reset sites are
   complete and the published property doesn't introduce observable
   double-publish during the monitor loop.
2. UI changes — confirm `.confirmationDialog` placement is correct for
   both macOS layouts, copy is on-tone, caption conditional inclusion
   is correct (no reserved space when not locked).

Status: **RDY**
