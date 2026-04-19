---
from: EN
to: QA
pri: P1
status: REQ
created: 2026-04-19
branch: fix/b3-b4-download-ui-bugs
---

## ctx

Integration test ask for the `cancelDownload()` subprocess termination path.
Unit tests in `CancelDownloadTests` (B3B4FixTests.swift) cannot exercise the
real Process termination because `activeDownloadProcess` is `nil` in the test
harness. This handoff captures the gap and asks QA to own a real-subprocess
integration test before ship.

Prior context: handoffs 060-067. C6 fix (067) added SIGKILL escalation + model
directory cleanup after cancel, but the code path is untested by any automated
test.

---

## ask

Write an integration test (separate file, e.g. `ModelManagerIntegrationTests.swift`,
gated `#if DEBUG`) that:

1. Starts a real long-running subprocess via `ModelManager.download()` — or
   directly via a `Process` that `sleep 10` (Python one-liner) to simulate a
   stalled download.
2. Calls `cancelDownload()` and asserts:
   a. `manager.state == .notDownloaded` within 100 ms (synchronous reset).
   b. `manager.isDownloadActive == false` within 100 ms.
   c. Within 3 seconds after cancel, the subprocess is no longer running
      (`ps aux | grep <pid>` returns nothing, or poll `proc.isRunning`).
   d. The model directory for the active backend is removed (H5 mitigation check).

3. Also test the SIGKILL escalation path by stubbing a process that catches SIGTERM
   and sleeps an additional 3 seconds before exiting. Assert the process is dead
   within 2.5 seconds (i.e. SIGKILL fires before test timeout).

---

## notes for QA

- `ModelManager` is `@MainActor`. Use `MainActor.run { }` when calling from
  async test contexts.
- `activeDownloadProcess` is `private` — the integration test may need to check
  process liveness via `proc.isRunning` captured before cancel, or poll via
  `kill(pid, 0)` (returns -1 with errno == ESRCH when the process is dead).
- The `waitForProcessExit` helper in `ModelManager` is `private static` — do not
  test it directly; test the observable effect (process dead + model dir removed).
- Real `download()` requires HuggingFace credentials and network. Use a mock
  Python script (`python3 -c "import time; time.sleep(30)"`) to simulate a stalled
  subprocess without network dependency. Inject it by temporarily overriding the
  download script argument, or expose a test seam if EN agrees to the API.

---

## ship-blocker status

This integration test is a **ship-blocker for the SIGKILL escalation guarantee**.
The H4 fix (terminate subprocess) was accepted with manual verification. C6 extends
that fix with a SIGKILL escalation that has never been run against a real process.
If QA cannot land this test before ship, document the manual repro steps in the
release checklist and require manual sign-off.

---

## refs

- `Murmur/Services/ModelManager.swift:448-518` — `cancelDownload()` implementation
- `Murmur/Tests/B3B4FixTests.swift:549-607` — `CancelDownloadTests` (unit, no real process)
- `docs/handoffs/067_EN_CR_DA_b3-b4-round4.md` — EN round-4 summary
