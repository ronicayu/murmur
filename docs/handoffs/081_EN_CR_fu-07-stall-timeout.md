---
from: EN
to: CR
pri: P2
status: RDY
created: 2026-04-19
refs: 080, FU-07
branch: fix/fu-07-download-stall-timeout
---

## ctx

FU-07 implementation: download stall timeout. Motivating scenario: user starts
model download, WiFi drops mid-transfer, app sits in `.downloading` forever
with no recovery path short of force-quit.

## design decisions

### Timeout value: 90 seconds
HuggingFace downloads on any real connection make some progress every 60s
even at 1 MB/s (the ONNX model is ~1.5 GB). 90s gives a grace window for
momentary network hiccups without leaving the user stuck indefinitely.
Hardcoded as `private static let stallTimeoutSeconds: TimeInterval = 90`
with an explanatory comment. No config knob — this is a single-user hobby
app, not a tunable server.

### New error case: MurmurError.downloadStalled
Chose a new case over reusing `.timeout(operation:)` because:
- `.timeout` is severity `.transient` (pill); a stalled download requires
  severity `.critical` (NSAlert) — the user must acknowledge and retry.
- Reusing `.timeout` would require reclassifying it or adding an overload;
  adding the new case is cleaner and the enum pattern is well-established.

Error copy:
- `shortMessage`: "Download stalled" (16 chars, fits pill)
- `alertTitle`: "Download stopped making progress"
- `errorDescription`: "The download isn't receiving data. Check your internet connection and try again."

### Pure stall-check predicate
Extracted to `nonisolated static func isStalled(lastProgressAt:now:timeout:)`
so the logic can be unit-tested without a real 90-second wait or running a
subprocess. The monitor task calls it with `Date()` for production use;
tests pass explicit dates.

### Cancel + error state sequencing
`cancelDownload()` sets state to `.notDownloaded` (existing contract).
After `cancelDownload()` returns in the monitor task, the monitor
immediately overrides state to `.error(MurmurError.downloadStalled.shortMessage)`
and `statusMessage` to the alert title, then `break`s the loop.
This ordering is safe: the monitor task runs on `@MainActor`, so there is
no concurrent state mutation between the cancel and the override.
The subprocess cleanup task (SIGTERM→SIGKILL + rmdir) runs detached — the
C8 guard inside `removePartialModelDirectory` checks `isDownloadActive`
before touching disk; since state is now `.error`, `isDownloadActive` is
false, and cleanup proceeds normally.

## file:line references

| Location | What |
|---|---|
| `Murmur/MurmurError.swift:4` | `case downloadStalled` |
| `Murmur/MurmurError.swift:32` | severity `.critical` for `.downloadStalled` |
| `Murmur/MurmurError.swift:47` | `shortMessage: "Download stalled"` |
| `Murmur/MurmurError.swift:62` | `alertTitle: "Download stopped making progress"` |
| `Murmur/MurmurError.swift:74` | `errorDescription` copy |
| `Murmur/Services/ModelManager.swift:208` | `stallTimeoutSeconds = 90` |
| `Murmur/Services/ModelManager.swift:559` | `isStalled(lastProgressAt:now:timeout:)` static func |
| `Murmur/Services/ModelManager.swift:521` | `lastProgressAt` tracking in monitor task |
| `Murmur/Services/ModelManager.swift:528` | reset on bytes-increase |
| `Murmur/Services/ModelManager.swift:535` | stall check + cancelDownload() + state override |
| `Murmur/Tests/DownloadStallTimeoutTests.swift` | all 10 tests |

## test coverage

**StallDetectionLogicTests** (6 tests, all < 1ms):
1. `test_isStalled_returnsFalse_whenNoTimeElapsed` — zero elapsed time
2. `test_isStalled_returnsFalse_whenProgressMadeWithinTimeout` — 30s < 90s
3. `test_isStalled_returnsTrue_whenTimeoutExactlyExceeded` — 91s > 90s
4. `test_isStalled_returnsFalse_atExactTimeoutBoundary` — 90s == 90s (documents >= semantics)
5. `test_isStalled_returnsFalse_whenRecentProgressReset` — 1s since last progress
6. `test_isStalled_respectsCustomTimeout` — 6s > 5s custom timeout

**DownloadStalledErrorTests** (4 tests, all < 1ms):
7. `test_downloadStalled_hasCriticalSeverity`
8. `test_downloadStalled_shortMessageIsActionable`
9. `test_downloadStalled_alertTitleDescribesProblem`
10. `test_downloadStalled_errorDescriptionGuidsUserToRecover`

All 10 pass. Full suite: 303 tests, 11 pre-existing failures in
`V3AXSelectReplaceTests` (AX accessibility, no focused text field in
headless test runner — tracked as FU-10).

## UI recovery path

Existing: when `ModelManager.state` is `.error(...)`, the onboarding view
and Settings sheet both show an error state with a "Try again" / "Download"
button that calls `download()` on tap. No new UI was required — the
NSAlert routing chain established in handoffs 076-080 handles display.
The stall error surfaces identically to any other download failure: NSAlert
(critical severity) with `alertTitle` + `errorDescription`, dismiss → user
clicks "Download" in UI to retry.

## constraints respected

- No subprocess zombie risk: `cancelDownload()` existing SIGTERM→SIGKILL
  escalation path is reused unchanged.
- No FU-03/FU-12 scope creep.
- No new UI built — "Download" button already works post-cancel.

## out

Commits (granular):
1. `2bf257f` — MurmurError.downloadStalled case + severity/copy
2. `511370a` — ModelManager stall detection in monitor task
3. `155033b` — Tests (10 tests, DownloadStallTimeoutTests.swift)

Build + installed to /Applications/Murmur.app. Ready for CR review.
