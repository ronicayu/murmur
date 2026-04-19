---
from: UT
to: PM
pri: P1
status: done
created: 2026-04-19
branch: fix/b3-b4-download-ui-bugs
---

## ctx

UAT pass on the B3/B4 download-UI bug fixes, from a first-time-user and power-user
perspective. Evaluated the onboarding download step (OnboardingView) and the
Settings > Model tab (SettingsView), along with the behaviors wired up through
ModelManager (state machine, setActiveBackend guard, cancel path).

No code was run — this is a walkthrough of the user-visible flow based on the
code that will render. Focus areas: download progress feedback, Next-button
auto-enable on completion, backend-switch lockout during download, cancel
behavior, and copy/language.

## ask

(originally) Walk seven scenarios, report UX severity + copy issues, produce
handoff for PM triage.

## refs

- `@EN/impl#b3-b4` round 4/5 — handoffs 067, 071
- `Murmur/Onboarding/OnboardingView.swift` (modelDownloadStep, backendCard)
- `Murmur/Onboarding/OnboardingViewModel.swift` (init Combine republish)
- `Murmur/Views/SettingsView.swift` (engineRow, modelStatusBadge, download buttons)
- `Murmur/Services/ModelManager.swift` (state enum, setActiveBackend, cancelDownload)

## out

### Overall verdict: SHIP with 0 P0 blockers

The core B3 (UI-update-on-completion) and B4 (isModelDownloaded not lying mid-
download) fixes behave correctly from a user's perspective. The "Continue" button
appears the moment `.ready` is reached, backend rows lock cleanly during download,
and cancel feels immediate. The remaining issues are all copy/polish and would
not hold ship, but there is one P1 worth a follow-up ticket (silent switch-
refusal with no explanation).

P0 count: **0**
P1 count: **2**
P2/polish count: **5**

---

### Scenario 1 — First-time onboarding: pick ONNX, click Download, wait — OK

What I see:
- Screen shows "Download Speech Model", a subtitle telling me the engine name
  and size, and a big blue "Download" button. Clear.
- I click Download. The button region swaps to a "Cancel" button, and a linear
  progress bar + status message + speed (e.g. "12 MB/s") appears below. Feels
  responsive and live.
- When the download completes, "Cancel" is replaced by a borderedProminent
  **"Continue"** button and a green "Model downloaded" checkmark. This is the
  B3 fix in action — it works. I don't have to click anything to "refresh", the
  Continue just appears.

Severity: **OK**. This is the exact behavior I'd expect from a modern macOS app.

Nits (P2):
- The button label in onboarding is **"Continue"** but in Settings completion
  is implicit (state badge flips to "Ready"). Minor inconsistency; not confusing
  because they are different contexts.
- The step header says "Download Speech Model" but after completion it still
  says that — the heading doesn't acknowledge success. The green label below
  carries the load. Fine, but a designer might want the heading to change to
  "Model Ready" on success for extra polish.

---

### Scenario 2 — Mid-download attempted backend switch — P1

What I see in onboarding (modelChoice step is auto-skipped, so this is really
only reachable via Settings): I'm downloading ONNX, I go to Settings > Model,
I click the "Whisper" or "HuggingFace" row in the Advanced disclosure.

Observed behavior (inferred from `.disabled(switchLocked && !isActive)` in
`engineRow`):
- The other rows are **disabled** (grayed out). The click does nothing at all —
  no visual feedback, no tooltip, no toast, no status message explaining why.
- A user who doesn't realize "because a download is running" would look at the
  grayed row and be left guessing. There's no hover help, no "Cannot switch
  while downloading" subtitle on the disabled row.

Severity: **P1 (annoying)**. Safe (no silent failure, no cancelled download),
but opaque. A real user — especially the power user switching engines to
compare — will click, nothing happens, and they'll feel like the app is broken.

Suggested copy fix (non-blocking, for PM triage):
- On the disabled row, show a muted caption under the size: "Locked during
  download" or "Available when download finishes". Two words of context.
- Alternatively, a `.help()` tooltip on the disabled button.

Same issue in `backendCard` on onboarding's modelChoice step, though this step
is currently auto-skipped so it's only hit by the Advanced disclosure in
Settings. Still worth fixing for symmetry.

---

### Scenario 3 — Cancel mid-download — OK (one polish nit)

What I see:
- I click "Cancel" (in onboarding) or "Cancel Download" (in Settings). The
  button label text is **different** between the two contexts — onboarding
  says "Cancel", Settings says "Cancel Download". Minor inconsistency.
- The UI returns to the "not downloaded" state essentially immediately — the
  state-reset is synchronous. In onboarding that means the blue "Download"
  button comes back. In Settings, the status badge flips from "Downloading..."
  to "Not Downloaded" and the download button reappears.
- **No confirmation dialog** ("Are you sure? You'll lose progress"). For a
  multi-GB model this is a little scary — a user who clicked Cancel by
  accident has no take-back.

Severity: **P2 (polish)**. Not a blocker — the affordance is obvious ("Cancel"
is a clear label) and the user can just hit Download again. But on a 3.5 GB
download, a "Cancel the 40% download?" confirmation would feel safer.

Also: the background cleanup (SIGKILL + rmdir) runs for up to ~2.1 s after
Cancel. The UI shows "not downloaded" immediately, which is the right tradeoff
from a responsiveness standpoint, but means a user who re-clicks Download
within 2 s is relying on the C8 race fix to work correctly (it does — the
cleanup task checks `isDownloadActive` before removing files). From a UX
standpoint this is invisible, which is correct.

---

### Scenario 4 — Cancel then immediately restart same backend — OK

What I see:
- I cancel. State flips to `.notDownloaded`. Big blue "Download" button
  reappears. I click it. A new download starts (fresh progress bar from 0).
- The C8 fix (cleanup skip if a new download started) makes this safe — the
  background cleanup Task detects `isDownloadActive == true` and skips the
  `removeItem` on the directory the new subprocess is actively writing.
- User-visible: feels like nothing weird happened. Download restarts cleanly.

Severity: **OK**. This is the scenario that had me worried (delete-while-writing)
and the fix appears to handle it correctly from a user-perceptible standpoint.

Nit (P2): progress bar resets to 0% even if partial bytes were on disk. Not a
bug — the partial was deleted or is being overwritten — but a user who cancels
at 80% and restarts might expect resume-from-80%. The current behavior is
"restart from scratch". That's fine; just set expectations via copy if it
becomes a complaint vector.

---

### Scenario 5 — Cancel then switch to different backend — OK

What I see:
- I cancel ONNX download. State flips to `.notDownloaded`, `isDownloadActive`
  becomes false synchronously.
- I immediately click Whisper in Settings. The engineRow click is no longer
  disabled (because `isDownloadActive == false`). `setActiveBackend(.whisper)`
  is accepted, activeBackend flips, status badge refreshes.
- Under the hood the ONNX cleanup Task is still running for ~2 s, but its guard
  re-checks `isDownloadActive`. If I've started a Whisper download in that
  window, the ONNX directory cleanup is skipped. That's slightly wrong (the
  cancelled ONNX directory could linger), but user-visible: nothing broken,
  and the next ONNX session will `refreshState()` and either treat it as
  `.ready` (if somehow complete) or `.corrupt` (if files are incomplete).

Severity: **OK** from a user perspective. The ONNX-dir-may-linger case is a
disk-hygiene issue, not a UX issue — filed as follow-up note, not a blocker.

---

### Scenario 6 — Settings backend switch with both models already downloaded — OK

What I see:
- I'm on ONNX (Downloaded badge visible, green checkmark on row). I click
  Whisper (Downloaded badge visible). `setActiveBackend(.whisper)` short-
  circuits nothing (different backend), assigns, persists UserDefaults, fires
  `committedBackendChange`, `refreshState()` runs.
- Status badge updates to "Ready" (assuming Whisper files are intact), model
  section heading updates to "Model — Whisper", checkmark moves. Fast and
  clean.
- If I click the **already-active** backend again, the C5 short-circuit
  returns `true` immediately with zero side effects — no spurious
  objectWillChange, no UserDefaults churn, no transcription-service rebuild.
  Invisible to the user (which is correct).

Severity: **OK**. The C5 short-circuit is exactly the right behavior.

---

### Scenario 7 — Visibility of download progress — OK with polish nits

What I see:
- Linear progress bar. Determinate when `progress >= 0`, indeterminate
  (spinner-like) when `progress < 0` (initial phase before the subprocess
  reports percentages). Good — not just a silent spinner forever.
- Status message (e.g. "Downloading…", "Verifying model files…", etc.)
  updates in-line.
- Transfer speed shown on the right ("12 MB/s"). Nice touch.

Severity: **OK** with three copy nits:

P2 nits on progress/status text:
1. **Speed formatter uses `bytesPerSec > 1_000_000`** — this displays as
   integer MB/s (e.g. "12 MB/s", never "12.4 MB/s"). For a long download a
   user would appreciate decimals on the low-MB end. Minor.
2. **No ETA / time remaining.** For a 3.5 GB model at a slow connection, "27%"
   alone doesn't tell me if I have 2 minutes or 40 minutes left. A calculated
   ETA from speed + remaining bytes would be a noticeable UX win.
3. **No total size in the progress readout.** "27%" is meaningful only if I
   remember the subtitle said "3.5 GB". "950 MB of 3.5 GB — 27%" would be
   clearer. Swift's `ByteCountFormatter` would make this a one-liner.

---

### Copy / language issues (aggregate)

| # | Where | Current | Suggestion | Sev |
|---|---|---|---|---|
| C1 | Onboarding download button during download | "Cancel" | "Cancel Download" (match Settings) | P2 |
| C2 | Settings disabled engine row | (no message) | Add muted caption "Locked during download" | P1 |
| C3 | Onboarding modelDownload heading after completion | "Download Speech Model" | Swap to "Model Ready" on `.ready` | P2 |
| C4 | Settings "Not Downloaded" badge | "Not Downloaded" | Fine; but confusing if state is `.error` and then user clicks Download again — the error message would be replaced silently. Not blocking, but watch for it. | P2 |
| C5 | OnboardingView status-message rendering | Hides status when downloading (it's in the progress row) but shows it otherwise. The condition `if case .downloading = state` then `else if !statusMessage.isEmpty` is correct but could show stale status after a cancel if statusMessage weren't cleared. | Confirmed `cancelDownload()` sets `statusMessage = ""` synchronously — good. | OK |
| C6 | engineRow "Downloaded" label | "Downloaded" | Fine. But no label for the _active_ backend's state — you only see the green checkmark on the row, and the "Ready" badge is in a different Section. Slight visual disconnect. | P2 |

---

### Top 3 findings

1. **[P1]** Disabled backend rows during download have **no explanation**.
   A user who clicks a grayed row and gets no response will assume the app is
   stuck. Add a "Locked during download" caption or tooltip. Same issue in
   OnboardingView.backendCard and SettingsView.engineRow.
2. **[P1]** No **confirmation dialog** before Cancel on a large in-flight
   download. One accidental click loses gigabytes of progress with no undo.
   Low implementation cost, high peace-of-mind.
3. **[P2]** Progress readout lacks **ETA** and **human-readable byte counts**
   ("950 MB of 3.5 GB"). Not blocking; would meaningfully improve the "am I
   stuck?" feeling on long downloads.

---

### UAT summary table

| # | Scenario | User experience | Severity |
|---|---|---|---|
| 1 | First-time onboarding, download ONNX | Clean. Continue auto-enables. | OK |
| 2 | Mid-download switch attempt | Silent lockout, no explanation | **P1** |
| 3 | Cancel mid-download | Immediate, but no confirmation | P2 |
| 4 | Cancel then redownload same backend | Clean restart | OK |
| 5 | Cancel then switch to different backend | Clean switch | OK |
| 6 | Switch backend with both downloaded | Clean, fast | OK |
| 7 | Download progress visibility | Clear but lacks ETA/byte counts | P2 |

---

### Recommendation to PM

**SHIP the B3/B4 fixes on this branch.** The bugs reported in 060 are closed
from a user's perspective. The two P1s above are polish items that can ride on
a follow-up branch — they are not regressions introduced by this work and do
not block the core bug fixes.

Suggest filing:
- `ui/engine-row-locked-caption` (P1) — covers finding #1
- `ui/cancel-download-confirmation` (P1) — covers finding #2
- `ui/download-progress-eta-bytes` (P2) — covers finding #3
- Copy-nit cleanup ticket for C1/C3/C6 table items above (P2)

Status: **SHIP**.
