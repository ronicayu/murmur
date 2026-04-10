# Handoff 029: PM → EN — Backend Reversal: V2 Back to ONNX

**Status:** REQ
**Date:** 2026-04-10
**From:** @PM
**To:** @EN

---

## Context

Rev 6 decision to use Whisper MPS for V2 was based on ONNX WER 24.4%. That number was wrong — jiwer did not normalize punctuation or casing, producing inflated WER.

Corrected results (normalized):

| Backend | Avg WER | Speed (per file) | Load | RAM |
|---------|---------|-------------------|------|-----|
| ONNX (CPU) | **3.9%** | 1-2s | 10s | ~300MB |
| Whisper (MPS) | **7.8%** | 3-8s | 7s | GPU memory |

ONNX wins on accuracy, speed, and RAM. No reason to use Whisper for V2.

## Decision

**V2 backend reverts to ONNX (Cohere q4f16).** Same model as V1. Spec updated to rev 7.

## What EN needs to do

1. **Fix spike WER calculation bug.** jiwer normalize must be applied before WER comparison. Known issue — fix the spike script so future benchmarks are correct.
2. **V2 pipeline uses ONNX, not Whisper.** No Whisper integration needed for V2.
3. **OOM fix still required.** ONNX batch mode OOMs on long audio. V2 must process chunks serially — same as rev 6 plan, just with ONNX instead of Whisper.
4. **Remaining Phase 0 tests** (chunk strategy, speed benchmark, multi-speaker, memory) should use ONNX.

## Spec changes (rev 7)

- `docs/specs/meeting-transcription.md` updated:
  - Revision 6 → 7
  - Backend section rewritten: V1+V2 unified on ONNX
  - Kill criteria updated: WER gate passed (3.9% < 20%)
  - Constraint #2 restored: same model for V1 and V2
  - WER row in Phase 0 table corrected

## Out

- Updated spec: `docs/specs/meeting-transcription.md` (rev 7)
- This handoff: `docs/handoffs/029_PM_EN_backend-reversal.md`
