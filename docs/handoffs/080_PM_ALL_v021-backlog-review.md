---
from: PM
to: ALL
pri: P2
status: done
created: 2026-04-19
refs: 076, 079
---

## ctx

v0.2.1 shipped. Real user is actively testing and has been iterating with EN
directly on UX polish. 10 backlog items are open (FU-02, 03, 05, 06, 07, 08,
09, 10, 11, 12). Before anyone grabs the next one, PM is reviewing the
backlog against the v0.2.1 reality: a user-facing hobby macOS app, V1 as the
primary path, tight feedback loops, minimalism and correctness over
completeness.

The test applied to every item: **will a real user (ours) hit a measurable
problem if we don't do this?** Inertia is not a reason to keep something.

## ask

(None — triage record. Next session picks from "Recommended next" below.)

## constraints

- V1 is the primary path the user actually uses. V3 bugs are lower urgency
  unless they leak into V1's UX.
- No onboarding-restart flow exists, so anything that only matters in that
  flow stays iceboxed.
- User prefers correctness + simplicity over instrumentation-for-its-own-sake.
- Test infrastructure investments (FU-03) must justify themselves against
  the likelihood of the bug recurring in code we'd actually ship.

## refs

- `076_PM_ALL_b3-b4-ship-decision.md` — original FU-01..FU-08 backlog
- `079_PM_ALL_v021-post-ship-closeout.md` — FU-09..FU-12 added; FU-01/FU-04 shipped
- `CHANGELOG.md` § 0.2.1

## out

### Triage

| ID | Title | New pri | Reasoning |
|---|---|---|---|
| FU-02 | ETA + human-readable byte counts in download progress | **P3** | Download runs once per install; user got through it fine without ETA. Polish, not a problem. |
| FU-03 | Subprocess-lifecycle integration test suite (SIGTERM→SIGKILL, cleanup, redownload race) | **P2** | Code is stable, user-tested, and cancel flow rarely changes. Keep as insurance, but not urgent without a regression signal. |
| FU-05 | Backend-aware guard in cleanup Task | **CUT** | Two-backend app, user doesn't switch backends mid-download in practice; the broader cleanup skip is benign. Revisit only if we add a third backend. |
| FU-06 | Surface setActiveBackend refusal in UI | **CUT** | Dead code path — no flow can hit `setActiveBackend` during an active download in current UI. Icebox forever unless onboarding-restart is built. |
| FU-07 | Download stall timeout | **P2** | Real failure mode (flaky network → app stuck forever with no user signal). Cheap fix, worth doing before more users install. |
| FU-08 | Migrate cancel to kqueue EVFILT_PROC | **CUT** | Theoretical PID-reuse race, zero evidence of occurrence, and FU-07 covers the user-visible "stuck" symptom. Over-engineering. |
| FU-09 | Bump `actions/checkout@v4` + `action-gh-release@v2` to Node-24 | **P3** | CI deprecation deadline is ~Sept 2026. Bump when it actually breaks or alongside the next CI touch. |
| FU-10 | 11 pre-existing test failures in V3AX + streaming integration | **P2** | User doesn't use V3, but a red suite is a broken trip-wire. Either fix or quarantine with `testDisabled`; don't leave CI lying. |
| FU-11 | `CFBundleShortVersionString` source-of-truth drift | **P3** | CI overrides from tag, only confuses local dev. Paper cut. |
| FU-12 | V3 streaming coordinator swallows transcription errors silently | **P1 → P2** | Real correctness gap, but scoped to V3 which the user doesn't use, and the pre-check workaround covers the "no model" symptom that surfaced it. Lower to P2; fix before any V3 promotion. |

**Cut: FU-05, FU-06, FU-08.** All three are residuals with no evidence of
real-world impact and no user to protect from them.

### Dependencies

- **FU-07 supersedes FU-08.** If `.downloading` stuck-state times out into
  `.error`, the PID-reuse window in cancel becomes a non-issue (user re-clicks
  Download, fresh PID). Don't do FU-08 without fresh evidence.
- **FU-12 partially covered by startRecording pre-check** (commit `c712021`).
  Pre-check catches "no model" at V1 entry; the underlying silent-swallow in
  V3 still exists but has no user-visible symptom today.
- **FU-03 would de-risk FU-07.** If we add a stall-timeout, a regression suite
  around download-lifecycle becomes more valuable. Sequence FU-07 first, then
  FU-03 if it feels load-bearing.

### Recommended next

Pull **one** item. This is a hobby app with one real user; batching creates
ship latency for no gain.

1. **FU-07 — Download stall timeout (P2, S).** Only item on the list with a
   plausible real-world failure mode our user could hit: flaky hotel wifi,
   corporate proxy, etc. Today the app sits in `.downloading` forever with no
   recourse. 1-line check + timer + state transition. Ships the same day it
   starts.

**Optional second** if EN has capacity after FU-07:

2. **FU-10 — Triage the 11 red tests.** Either fix them or mark disabled with
   a filed reason. A lying CI suite erodes trust in every future "green" and
   costs nothing to quarantine.

**Everything else waits for a real-world signal.** That includes FU-03,
FU-12, FU-02, FU-09, FU-11. If the user doesn't hit them, they don't need
doing.

### Scope worth formalizing?

**No formal UX-principles doc.** The post-079 polish (audio feedback tuning,
pill simplification, NSAlert routing, `MurmurError.Severity`) is three
principles the code already encodes:

1. **Sound only signals system events the user can't see** (start = yes;
   stop/success = no, the text appearing is the confirmation).
2. **Pill = transient info; NSAlert = user must act.** Severity on the error
   enum picks the route.
3. **Simplify when the UI duplicates visible state** (pill dropped text
   preview + "⌘Z to undo" because the inserted text is right there).

These are short enough that a doc would decay faster than the code. Leave
them as code + commit messages. If a fourth principle surfaces and they start
conflicting, then write the doc. Not before.

One exception: **add a 1-line comment on `MurmurError.Severity`** noting the
NSAlert-vs-pill routing rule. That's load-bearing, non-obvious from the type
name, and a future contributor will otherwise guess wrong.

### Resolution

Status: **done**. Next session: EN picks up FU-07. Everything else parked
until a user report or a touched-while-here moment surfaces it.
