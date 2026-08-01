import Foundation

/// Poll `condition` (evaluated on the MainActor) until it returns true or
/// `timeout` elapses. Returns whether it became true within the budget.
///
/// Replaces fixed-duration `Task.sleep` waits in timing-sensitive tests.
/// A single fixed sleep is racy: if the machine is under load (e.g. the full
/// parallel `swift test` on a CI runner), a detached poller or async task can
/// slip past the sleep window and the assertion fires against stale state.
/// Polling returns as soon as the work is observably done (fast in the common
/// case) but tolerates a slow machine up to `timeout` — deterministic in
/// outcome, not dependent on one sleep landing after the work completes.
@discardableResult
func pollUntil(
    timeout: TimeInterval = 2.0,
    pollInterval: TimeInterval = 0.02,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await MainActor.run(body: condition) { return true }
        try? await Task.sleep(for: .seconds(pollInterval))
    }
    return await MainActor.run(body: condition)
}
