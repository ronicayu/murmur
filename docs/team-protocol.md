# Team Protocol

Living document. Every agent reads this before starting work. Update it when the way of working changes.

## Roster

| Tag  | Agent                  | Owns                                      |
|------|------------------------|--------------------------------------------|
| `PM` | staff-product-manager  | Vision, roadmap, backlog, triage, scope    |
| `EN` | tdd-staff-engineer     | Implementation (TDD), architecture         |
| `CR` | staff-code-reviewer    | Code review, quality gates                 |
| `QA` | qa-test-engineer       | Test coverage, automation, test plans      |
| `UX` | ux-flow-designer       | Flows, wireframes, interaction, visual dir |
| `UT` | uat-user-tester        | User perspective, UAT, usability feedback  |
| `DA` | devils-advocate        | Challenge assumptions, find gaps, stress-test decisions |

## Handoff Protocol

Agents communicate through **handoff blocks** in `docs/handoffs/`. One file per handoff, named `{seq}_{from}_{to}_{topic}.md`. Sequence numbers are zero-padded 3 digits.

### Handoff format

```
---
from: PM
to: UX
pri: P1
status: open | wip | done | blocked
created: 2026-04-08
---

## ctx
One paragraph of context. Why this matters now.

## ask
Numbered list of concrete deliverables requested.

## constraints
Bullet list of non-negotiable constraints (scope, perf, platform, deadline).

## refs
Links to files, prior handoffs, or external resources.

## out
(Filled by receiver) Deliverables or response.
```

### Compact inline references

When agents reference each other's work inside any document, use this shorthand:

```
@PM/roadmap        → PM's current roadmap decision
@EN/impl#auth      → EN's implementation, auth module
@CR/review#042     → CR's review #042
@QA/plan#onboard   → QA's test plan for onboarding
@UX/flow#settings  → UX's flow design for settings
@UT/uat#onboard    → UT's UAT session for onboarding
```

## Workflow: Feature Lifecycle

```
PM ──spec──> DA ──challenge──> PM ──revise──> UX ──flow──> DA ──challenge──> PM ──approve──> EN ──code──> DA+CR ──review──> EN ──fix──> QA ──test──> UT ──uat──> PM ──ship/iterate
                                                                                                        │                                       │
                                                                                                        └──────── parallel if independent ───────┘
```

1. **PM** writes a spec (problem, success metric, constraints, size).
2. **DA** challenges the spec: wrong assumptions? missing edge cases? scope too big/small?
3. **PM** revises spec based on DA feedback.
4. **UX** designs the flow and visual direction. Gets **UT** gut-check on confusing parts.
5. **DA** challenges UX: what breaks? what's confusing? what's over-designed?
6. **PM** approves scope. Hands off to **EN**.
7. **EN** implements via TDD (red-green-refactor). Requests **CR** review when green.
8. **DA + CR** review in parallel. DA challenges architecture; CR reviews code quality.
9. **QA** writes/runs automated tests. Produces coverage report.
10. **UT** performs UAT from user perspective. Returns structured feedback.
11. **PM** triages UT feedback. Ships or sends back for iteration.

### Parallel tracks

- **UX + UT** can run concurrently during design phase (UX designs, UT reacts).
- **CR + QA** can run concurrently after implementation (review + test in parallel).
- **EN** can start next item while **CR/QA** review current item.

## Decision Rights

| Decision                     | Decider | Consulted     |
|------------------------------|---------|---------------|
| What to build & priority     | PM      | UX, UT        |
| How the UX works             | UX      | UT, PM        |
| How the code works           | EN      | CR            |
| Is the code ready            | CR      | EN, QA        |
| Is the test coverage enough  | QA      | CR, EN        |
| Is the UX acceptable to user | UT      | UX, PM        |
| Are assumptions valid        | DA      | PM, EN, UX    |

## Status Shorthand

Agents use these in handoff status fields and inline updates:

```
REQ     → requested, not started
WIP     → in progress
BLK:x   → blocked on x (e.g., BLK:PM/scope)
RDY     → ready for next stage
LGTM    → approved, move forward
CHG:n   → needs n changes (e.g., CHG:2)
SHIP    → ready to ship
PUNT    → deferred (with reason)
```

## Evolution Rules

1. Any agent can propose a protocol change by adding a `## Proposed Change` section at the bottom.
2. PM approves process changes that affect scope/priority. EN approves changes that affect code workflow.
3. After approval, the proposer updates the protocol and removes the proposal section.
4. Keep this document under 200 lines. If it grows, split into sub-documents.
