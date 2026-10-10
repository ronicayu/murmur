import Foundation

/// Carries the "stop this recording" signal from a recording's timers (max
/// duration, hands-free trailing silence) to whoever owns the recording.
///
/// The handler is written on the main actor and the timers run on background
/// tasks, so both are kept behind a lock. Every recording gets its own session
/// number; a timer that fires after its recording ended, or after the next one
/// began, is dropped instead of stopping a recording it does not belong to.
final class AutoStopRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: (@Sendable () -> Void)?
    private var session = 0

    var handler: (@Sendable () -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock(); defer { lock.unlock() }
            storedHandler = newValue
        }
    }

    /// Start a new recording session. Timers of earlier sessions can no
    /// longer fire. Returns the number this session's timers must pass to `fire`.
    func beginSession() -> Int {
        lock.lock(); defer { lock.unlock() }
        session += 1
        return session
    }

    /// End the current session: its timers can no longer fire.
    func endSession() {
        lock.lock(); defer { lock.unlock() }
        session += 1
    }

    /// Invoke the handler if `session` is still the current recording.
    func fire(session firing: Int) {
        lock.lock()
        let current = firing == session ? storedHandler : nil
        lock.unlock()
        current?()
    }
}
