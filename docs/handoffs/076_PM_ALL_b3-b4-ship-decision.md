---
from: PM
to: ALL
pri: P0
status: SHIP
created: 2026-04-19
branch: fix/b3-b4-download-ui-bugs
commit-head: f698354
refs: 060, 061, 062, 063, 064, 065, 066, 067, 068, 069, 070, 071, 072, 073, 074, 075
---

## verdict

**SHIP — merge to main, release as v0.2.1.**

Five rounds of review converged. DA LGTM (072). CR LGTM (069). QA sign-off with
four named gaps (073, test footgun fixed in 075). UT SHIP, 0 P0, 2 P1 polish
(074). The branch closes B3 and B4 — two user-visible v0.2.0 bugs — and hardens
the cancel path with SIGKILL escalation that the previous code never had.

## reasoning

- **B3/B4 are live user bugs in v0.2.0.** Every day this branch sits is a day
  users hit "Continue" never appearing after download, or a "Downloaded" badge
  that lies mid-download. The branch ships a correct fix for both.
- **H9 integration-test gap is for a path the branch improves, not regresses.**
  The SIGTERM-async bug existed in main. This branch adds SIGKILL escalation
  with manual verification + CR code-inspection sign-off. Holding v0.2.1 to
  land the `__testing_injectDownloadProcess` seam means users keep hitting
  B3/B4 while we test code that was already worse before. The integration
  suite gets filed as a follow-up and can land in v0.2.2.
- **UT P1s are polish, not regressions.** Both P1 items (disabled-row caption,
  cancel-confirm dialog) are pre-existing UX gaps amplified by the new guard,
  not caused by it. File and sequence into the next UX pass.

## UT P1 triage

| UT item | Verdict | Priority | Rationale |
|---|---|---|---|
| Disabled backend rows silent during download | Defer | P1 | Opaque but not broken. Caption/tooltip is a 1-line SwiftUI change; bundle with other download-UI polish in v0.2.2. |
| No confirmation dialog before Cancel on multi-GB download | Defer | P1 | Agree it's scary. But user can just re-click Download and the C8 guard handles restart cleanly. Not worth gating v0.2.1. |
| "Cancel" vs "Cancel Download" copy | Defer | P2 | Ride on the same download-UI polish ticket. |

## follow-up backlog

| ID | Title | Pri | Owner | Size | Source |
|---|---|---|---|---|---|
| FU-01 | Download-UI polish: disabled-row caption + cancel-confirm dialog + copy consistency | P1 | UX -> EN | S | UT 074 P1s + copy table |
| FU-02 | Download progress: show ETA + human-readable byte counts ("950 MB of 3.5 GB, ~2m left") | P2 | UX -> EN | S | UT 074 finding #3 |
| FU-03 | Integration test suite for cancelDownload subprocess lifecycle (C6/H4/H7/H9) | P1 | EN + QA | M | QA 073 Section 2; requires `__testing_injectDownloadProcess(_:)` seam |
| FU-04 | Per-backend manifest verification (hash/size) in isModelDownloaded + refreshState | P1 | EN | M | H5/H8/M5 deferred from 063/067/069; stops "Downloaded" label lying on orphan partial dirs |
| FU-05 | Backend-aware guard in cleanup Task (scope skip to `activeBackend == backend`) | P2 | EN | S | DA 072 accepted residual #1 |
| FU-06 | Surface setActiveBackend refusal in UI (onboarding + settings) when future flows can hit it mid-download | P3 | EN | S | M4 from 073 risk 5; icebox until an onboarding-restart flow is actually planned |
| FU-07 | Download stall timeout: move state to `.error("timed out")` if `.downloading` persists N minutes with no progress | P2 | EN | S | QA 073 risk 3 |
| FU-08 | Migrate kill-then-poll cancel to kqueue EVFILT_PROC (removes PID-reuse window entirely) | P3 | EN | M | M6 accepted residual; only pursue if FU-07 or user reports make it load-bearing |

Cut from triage: zero. I re-read and everything on the list traces to an
evidence-backed finding from a named handoff.

## merge strategy

**Merge commit (no squash, no rebase).**

- 20+ commits with a dense review narrative across 16 handoffs. Squashing
  destroys the chain that shows why each fix exists and which round introduced
  it.
- Rebase rewrites timestamps on the EN/CR/DA commits, which makes the handoff
  `commit-reviewed` references in 069/070/072 unverifiable.
- Merge commit preserves per-commit bisectability and the full audit trail. The
  one-time cost is a slightly noisier `main` graph — worth it for a branch
  that went through 5 DA/CR rounds and will be referenced in post-mortems.

Command the user should run (do not run it yourself):

```
git checkout main
git pull --ff-only
git merge --no-ff fix/b3-b4-download-ui-bugs -m "Merge B3/B4 download UI bug fixes (v0.2.1)"
# then tag v0.2.1 and push
```

## proposed PR title + body

**Title:**
```
Fix B3/B4 download UI bugs: live state propagation + active-download safety
```

**Body:**
```
## Summary

Fixes two v0.2.0 bugs in the model download flow and hardens the cancel path:

- **B3**: OnboardingView now auto-advances to "Continue" the moment
  `.ready` is reached. Fixed by forwarding `ModelManager.objectWillChange`
  into `OnboardingViewModel` via Combine republish (no `.receive(on: main)`
  hop — synchronous delivery).
- **B4**: `isModelDownloaded(for:)` now returns true only on positive
  assertion (`state == .ready` + required files present). It no longer lies
  during an active download on the inactive-backend path.
- **Cancel hardening**: `cancelDownload()` now escalates SIGTERM -> SIGKILL
  after 2s and cleans the partial model directory. Cancel->redownload race
  guarded via MainActor-hopped `isDownloadActive` check before `removeItem`
  (C8). Backend-switch lockout during active download via `setActiveBackend`
  guard (C3/C4/C5) so users can't trigger UserDefaults/state churn mid-DL.

## Review trail

5 rounds of DA + CR, resolved in handoffs 060-075. Final gates:
- DA LGTM: `072_DA_EN_b3-b4-round5-challenge.md`
- CR LGTM: `069_CR_EN_b3-b4-round4-review.md`
- QA: `073_QA_PM_b3-b4-coverage.md` (39 tests; integration gaps filed as FU-03)
- UT SHIP: `074_UT_PM_b3-b4-uat.md` (0 P0, 2 P1 polish filed as FU-01)
- PM ship: `076_PM_ALL_b3-b4-ship-decision.md`

## Test plan

- [x] Unit: 39 new tests across B3B4FixTests + ModelSwitchingTests, all green
- [x] Full suite: 274 tests pass (11 pre-existing AX failures unrelated)
- [x] Manual: cancel mid-download, cancel+redownload, backend switch mid-DL
- [ ] Follow-up (FU-03): automated subprocess-lifecycle integration suite

## Deferred

FU-01..FU-08 filed in 076. FU-01 (UT P1 polish) and FU-03 (integration
tests) are next up.
```

## asks

- **User**: run the merge command above, tag v0.2.1, update CHANGELOG and
  README notes for B3/B4, then push. I am explicitly NOT running those
  commands.
- **UX**: pick up FU-01 when capacity allows; S-sized and unblocks a real
  user friction point.
- **EN + QA**: pair on FU-03 next sprint — the `__testing_injectDownloadProcess`
  seam is the prerequisite.
- **EN**: when you next touch `removePartialModelDirectory`, take FU-05
  (backend-aware guard) for free.

## resolution

This handoff closes the B3/B4 ship chain. All prior handoffs in the chain
(060-075) are resolved. FU-01..FU-08 carry forward as backlog items.

Status: **SHIP**.
