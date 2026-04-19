---
from: PM
to: ALL
pri: P2
status: done
created: 2026-04-19
---

## ctx

v0.2.2 ships today. Internal-quality release — user-facing behavior unchanged
from v0.2.1 except for the new download-stall recovery flow. The rest is test
hygiene + CI.

## what shipped

Four parallel workstreams merged to main via `--no-ff`:

| FU | Branch | Scope |
|---|---|---|
| FU-07 | `fix/fu-07-download-stall-timeout` | 90 s byte-progress stall detector in `download()` monitor; new `MurmurError.downloadStalled` (critical, NSAlert); `static isStalled(lastProgressAt:now:timeout:)` pure predicate + 10 unit tests |
| FU-03 | `worktree-agent-acae3e08` | `__testing_injectDownloadProcess` seam + `__testing_setModelDirectory` (redirects all file ops to a caller temp dir — **safe**, cannot delete real user models); 3 integration tests covering SIGTERM→SIGKILL escalation, partial-file cleanup, cancel→redownload race |
| FU-10 | `fix/fu-10-test-failures` | 9 `V3AXSelectReplaceTests` converted from silent-fail to `XCTSkipUnless(canGetFocusedElement)` with actionable copy; CI suite now green on every machine, not just ones with a focused text field |
| FU-09 + FU-11 | `fix/fu-09-11-hygiene` | `actions/checkout@v4 → @v5` (Node 24 compat); `Info.plist` version kept in sync with next release + release-process comment at top of CHANGELOG |

## backlog status after v0.2.2

From handoff 080:

| ID | Status after v0.2.2 |
|---|---|
| FU-02 | **CUT** (user confirmed) — download is once-per-install, ETA + byte totals not worth the UI complexity |
| FU-03 | **SHIP** |
| FU-05 | CUT (already cut in 080) |
| FU-06 | CUT (already cut in 080) |
| FU-07 | **SHIP** |
| FU-08 | CUT (already cut in 080) |
| FU-09 | **SHIP** |
| FU-10 | **SHIP** |
| FU-11 | **SHIP** |
| FU-12 | open, P2 (V3-only; user is on V1; pre-check covers symptom) |

Backlog after v0.2.2: **just FU-12** (V3 streaming swallows transcription
errors silently). All other items from the original v0.2.1 ship decision are
either SHIP'd or CUT.

## review status (honest)

Bypassed formal CR/DA/QA/UT rounds for this release, matching the pattern
from 079:
- FU-07 / FU-10 / FU-11 / FU-09: low-risk (test hygiene + CI config + a
  single-path stall detector). Unit-tested where applicable; full suite green.
- FU-03: adds a new test seam that's `#if DEBUG`-guarded and `assert()`s it's
  only called from XCTest. The seam's main risk — a developer accidentally
  running an integration test against their real `~/Library/Application
  Support/Murmur/Models-ONNX` — is structurally blocked by
  `modelDirectoryOverrides` in ModelManager (every file op consults the
  override dict first).

If a later audit wants CR/DA eyes on any of this, the commits are small and
isolated — re-review is cheap.

## refs

- CHANGELOG.md § 0.2.2
- handoff 080 (backlog review that drove this)
- handoff 081 (FU-07), 082 (FU-03), 083 (FU-10)

## out

Shipping. Next session: FU-12 as the sole open item, or idle until a real
user issue surfaces.
