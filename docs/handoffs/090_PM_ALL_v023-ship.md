---
from: PM
to: ALL
pri: P2
status: SHIP
created: 2026-04-20
---

## ctx

v0.2.3 merged to `main` via `--no-ff` (`feat/language-badge-on-pill` →
commit `48b76c6`). Version bumped in `Murmur/Info.plist`; CHANGELOG entry
written. Tag + CI release not yet cut — user holds that trigger.

Single-feature release driven by one user request: "show me which
language the model thinks I'm speaking before I commit." Went through the
planned PM → EN → CR/QA loop, then picked up two UAT-driven follow-ups
during install testing.

## what shipped

### Planned (handoffs 085–089)
- **Language badge on the recording pill.** Small `EN` / `ZH` style chip
  between the state icon and "Recording…" text. When the language setting
  is `Auto`, the badge gets a trailing middle dot (`EN·`, `ZH·`) to signal
  the value came from the active macOS keyboard input source rather than a
  fixed Settings choice.
- Layout reworked from a corner overlay to inline (`[●] [ZH·] Recording…`)
  after UAT showed the overlay was visually awkward and crowded the dot.

### Unplanned, UAT-driven during install
- **Esc-to-cancel-recording fixed.** Previously broken on the user's
  install: `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`
  registered successfully but never delivered keyDown events (verified via
  debug log) while the sibling `flagsChanged` monitor kept working — so
  right-cmd-to-record worked but Esc didn't. Replaced with a Carbon
  `RegisterEventHotKey` registration via the existing `HotKey` package,
  installed when recording starts and torn down when it ends.
- **Cancel button on the pill** (`xmark.circle.fill`) added in the same
  change so users have both keyboard and click options. Routes through
  the same `.cancelRecording` path as Esc.

## known gaps / didn't ship

- QA flagged a desire for a **V3 streaming integration test** that exercises
  the badge during a live transcription session. Deferred — current
  coverage exercises badge state transitions in isolation; the streaming
  path doesn't touch badge logic, so risk is low.
- Esc is now **exclusively grabbed by Murmur** while a recording is active
  (Carbon hotkey side effect). No user complaints during UAT, but worth
  flagging if anyone hits it later.

## platform learning to record

`NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` is **unreliable**
on at least some macOS installs — it registers and reports no error but
silently never fires. `flagsChanged` on the same API path appears
unaffected. **For any future global keyDown handling in Murmur, use Carbon
`RegisterEventHotKey` (the `HotKey` package wraps it) instead of the
NSEvent global monitor.** The NSEvent global monitor is fine for modifier
keys but should not be trusted for plain key events.

## next steps for user

To actually ship the release:

1. Tag on `main`: `git tag v0.2.3 && git push origin v0.2.3`
2. CI's `release.yml` will build, sign, and publish the DMG — overrides
   the plist version from the tag, so the bump in `Info.plist` is just for
   local-build sanity.
3. Verify the GitHub release lands; spot-check the DMG installs and the
   badge + Esc both behave on a clean machine.
4. If CI fails, the recovery pattern from v0.2.1 / v0.2.2 applies:
   force-move tag to a fixed commit, re-push.

## refs

- `CHANGELOG.md` § 0.2.3
- handoffs 085 (PM spec), 086 (EN impl r1), 087 (CR review), 088 (QA + UAT),
  089 (EN round 2)
- `084_PM_ALL_v022-ship.md` — prior ship handoff for format reference
- merge commit `48b76c6`; feature commits `3907343`, `cae1c9e`, `9e52531`,
  `ac26932`

## out

Shipping. Backlog after v0.2.3 is unchanged from v0.2.2 closeout: just
**FU-12** (V3 streaming swallows transcription errors) remains open. No
new items surfaced from this cycle worth tracking — the Esc/Carbon fix
was a one-shot platform finding, captured above.
