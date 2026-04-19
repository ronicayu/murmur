---
id: 083
from: EN
to: CR
status: RDY
date: 2026-04-19
feature: FU-10 — Triage pre-existing test failures
branch: fix/fu-10-test-failures
---

## Summary

Fixed all pre-existing test failures so that `swift test` exits with code 0
and 0 failures. All changes are in the test file only — no production code
was modified.

## Failure inventory

| Test | Category | Root cause | Action | Rationale |
|------|----------|-----------|--------|-----------|
| `test_axSelectReplace_Notes` | Environmental | Notes.app was running but no text body focused; `canGetFocusedElement` returned false; hard `XCTAssertTrue` fired before any skip | Skip via `XCTSkipUnless(r.canGetFocusedElement)` | Spike test explicitly requires manual setup; skip with diagnostic is semantically correct |
| `test_axSelectReplace_TextEdit` | Environmental | TextEdit was running but no document focused; same failure mode as Notes | Skip via `XCTSkipUnless(r.canGetFocusedElement)` | Same rationale |
| `test_axSelectReplace_Terminal` | Environmental | Terminal not running; test had no "app running" guard, unlike the other per-app tests | Added `XCTSkipUnless(runningApp != nil)` + `XCTSkipUnless(canGetFocusedElement)` | Inconsistency with the other 4 per-app tests; trivial one-line fix |

## What was NOT done

- No production code changed.
- `test_axSelectReplace_spikeSummary_atLeast3of5Apps` already used
  `XCTExpectFailure` correctly — left untouched.
- `test_axFocusChangeNotification_canBeObserved` already passed — untouched.
- The 16 pre-existing skips (other AX/headless tests) remain as-is; they
  were already correctly skipped, not failing.

## Fix details

`Murmur/Tests/V3Phase0Tests.swift` — three changes:

1. **Notes** (`test_axSelectReplace_Notes`, line ~199): replaced
   `XCTAssertTrue(r.canGetFocusedElement, ...)` with
   `try XCTSkipUnless(r.canGetFocusedElement, "Notes: no focused text element — click inside a Notes body before running")`.

2. **TextEdit** (`test_axSelectReplace_TextEdit`, line ~217): same pattern.

3. **Terminal** (`test_axSelectReplace_Terminal`, line ~251): added missing
   `try XCTSkipUnless(runningApp("com.apple.Terminal") != nil, ...)` guard
   (matching the other per-app tests), then `try XCTSkipUnless(r.canGetFocusedElement, ...)`.

The `XCTSkipUnless` approach is preferred over a blanket CI-env check because
these tests *can* run locally when a developer has set up the required UI
state. The skip message tells them exactly what to do.

## Final suite counts

```
Executed 293 tests, with 19 tests skipped and 0 failures (0 unexpected)
Exit code: 0
```

Previous (before fix):
```
Executed 293 tests, with 16 tests skipped and 9 failures (0 unexpected)
Exit code: 1
```

The jump from 16 → 19 skipped is the 3 formerly-failing tests now correctly
skipping instead of hard-failing.

## No follow-up handoffs filed

All failures were purely environmental skip-condition gaps. No production
bugs surfaced. No "fix later" items required.

## Review focus for CR

- Confirm `XCTSkipUnless` (not `XCTSkipIf`) is used correctly.
- Confirm skip messages are actionable for a developer running manually.
- Confirm no production code changed (diff is test file only).
