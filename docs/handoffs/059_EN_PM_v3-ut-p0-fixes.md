# Handoff 059 — EN → PM: V3 UT P0 Fixes

**From:** EN
**To:** PM
**Status:** RDY
**Date:** 2026-04-10
**Re:** V3 Streaming — UT-058 P0 fixes (chunk label + silent replacement)

---

## UT-P0-1: Pill shows debug "chunks" count ✓

**File:** `Views/FloatingPillView.swift`

Streaming pill changed from:
- "Streaming..." + "3 chunks" (debug language)

To:
- "Listening..." + "Esc to cancel" (user language)

"Listening" is more natural than "Streaming" for voice input. Chunk count removed entirely — it's an internal metric with no user value.

Accessibility label simplified accordingly.

---

## UT-P0-2: Full-pass replacement happens silently ✓

**Files:** `Services/StreamingTranscriptionCoordinator.swift`, `AppCoordinator.swift`, `Views/FloatingPillView.swift`

Three changes:

1. **Coordinator** exposes `fullPassReplacedText: String?` — set when `replaceRange` succeeds.

2. **AppCoordinator** `stopAndTranscribeStreaming()` now checks `fullPassReplacedText`:
   - If replacement happened → transitions to `.undoable(text:method:)` state, shows pill for 3s
   - If no replacement → transitions to `.idle` as before

3. **Pill** `.undoable` state now shows "⌘Z to undo" subtitle below text preview, so user knows text was refined and can revert.

User experience after fix:
- Dictate → text appears chunk by chunk → release hotkey → if text is refined, pill shows green checkmark + refined text + "⌘Z to undo" for 3 seconds → auto-dismiss

---

## Modified files

- `Murmur/Views/FloatingPillView.swift`
- `Murmur/Services/StreamingTranscriptionCoordinator.swift`
- `Murmur/AppCoordinator.swift`

---

## in

- `docs/handoffs/058_UT_PM_v3-uat.md`

## out

`docs/handoffs/059_EN_PM_v3-ut-p0-fixes.md` — both UT P0s fixed. P1s (CPU fallback indicator, focus-abandon notification) deferred to Phase 2.
