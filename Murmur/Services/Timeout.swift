import Foundation

/// Run `body`, but stop waiting for it after `seconds`.
///
/// The caller gets `MurmurError.timeout` at the deadline even when `body`
/// ignores cancellation (audio engine calls and model inference both do). A
/// task group cannot do that: it waits for every child before it rethrows, so
/// the timeout would only be reported once the stuck call returned.
///
/// `body` keeps running after a timeout. `onLateCompletion` is called with its
/// eventual outcome, so the caller can release whatever it produced.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: String,
    onLateCompletion: (@Sendable (Result<T, Error>) -> Void)? = nil,
    body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = TimeoutRace()
    let work = Task<T, Error> { try await body() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let deadline = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, race.claim() else { return }
                work.cancel()
                continuation.resume(throwing: MurmurError.timeout(operation: operation))
            }
            Task {
                let result = await work.result
                deadline.cancel()
                if race.claim() {
                    continuation.resume(with: result)
                } else {
                    onLateCompletion?(result)
                }
            }
        }
    } onCancel: {
        work.cancel()
    }
}

/// Decides which of the two racers (the work or the deadline) answers the caller.
private final class TimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var decided = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if decided { return false }
        decided = true
        return true
    }
}
