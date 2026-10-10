import Foundation

/// Runs `action` once `seconds` have passed without a `touch()`.
final class IdleTrigger: @unchecked Sendable {
    private let seconds: TimeInterval
    private let action: @Sendable () async -> Void
    private let lock = NSLock()
    private var countdown: Task<Void, Never>?

    init(seconds: TimeInterval, action: @escaping @Sendable () async -> Void) {
        self.seconds = seconds
        self.action = action
    }

    deinit { countdown?.cancel() }

    /// Starts the countdown again from now.
    func touch() {
        let next = Task { [seconds, action] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await action()
        }
        lock.withLock {
            countdown?.cancel()
            countdown = next
        }
    }

    /// Stops the countdown. `touch()` starts a new one.
    func cancel() {
        lock.withLock {
            countdown?.cancel()
            countdown = nil
        }
    }
}
