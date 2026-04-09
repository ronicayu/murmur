# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Input** is a macOS voice input app (similar to 闪电说). It uses the local Cohere Transcribe model for speech-to-text, with no cloud dependency after initial model download.

Key requirements:
- macOS native app (Swift, AppKit/SwiftUI)
- Local-only transcription via Cohere Transcribe
- Onboarding flow that includes model download
- Acts as a system-wide input method

## Status

This project is in the planning phase. See `docs/plan.md` for the product brief.

## Team

This repo is developed by a team of specialized agents. Read `docs/team-protocol.md` before doing any work — it defines roles, handoff format, and workflow.

### Agent roster (shorthand tags)

| Tag  | Agent                  | Focus                                    |
|------|------------------------|------------------------------------------|
| `PM` | staff-product-manager  | Vision, roadmap, backlog, triage, scope  |
| `EN` | tdd-staff-engineer     | Implementation (TDD), architecture       |
| `CR` | staff-code-reviewer    | Code review, quality gates               |
| `QA` | qa-test-engineer       | Test coverage, automation, test plans    |
| `UX` | ux-flow-designer       | Flows, wireframes, visual direction      |
| `UT` | uat-user-tester        | User perspective, UAT, usability         |
| `DA` | devils-advocate        | Challenge assumptions, find gaps, stress-test |

### How agents work together

- **Handoffs** go in `docs/handoffs/` using the format defined in the team protocol.
- **Inline references** use `@TAG/artifact#topic` shorthand (e.g., `@PM/roadmap`, `@EN/impl#auth`).
- **Status codes**: `REQ`, `WIP`, `BLK:x`, `RDY`, `LGTM`, `CHG:n`, `SHIP`, `PUNT`.
- **Feature lifecycle**: PM spec -> DA challenge -> PM revise -> UX flow -> DA challenge -> PM approve -> EN code -> DA+CR review -> QA test -> UT uat -> PM ship.
- Parallel tracks are encouraged: UX+UT during design, CR+QA after implementation.

### Before you start work

1. Check `docs/handoffs/` for any open handoffs addressed to you.
2. Read the team protocol (`docs/team-protocol.md`) if this is your first session.
3. Write a handoff when passing work to another agent.
4. Update your handoff status when done (`out` section + status field).

### Evolving the process

Any agent can propose changes to `docs/team-protocol.md`. PM approves scope/priority changes; EN approves code workflow changes. Keep the protocol under 200 lines.
