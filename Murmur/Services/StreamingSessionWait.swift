import Combine
import Foundation
import os

private let waitLog = Logger(subsystem: "com.murmur.app", category: "streaming")

extension StreamingTranscriptionCoordinator {
    /// Hard backstop timeout for `waitUntilEnded`, independent of state emissions.
    /// Prevents UI hang if coordinator gets stuck without emitting new state (NEW-P1-2).
    static let endBackstopSeconds: TimeInterval = 50
    /// Soft deadline of the same wait. Both sit above the coordinator's own
    /// 30 s full-pass timeout (plus up to ~5 s to finish the streamed text),
    /// so the coordinator ends the session with what it has before the owner
    /// gives up on it.
    static let endDeadlineSeconds: TimeInterval = 45

    /// Returns when the session has ended (done, cancelled or failed). The
    /// owner calls this after `endSession()`. A session that does not end by
    /// itself is cancelled at the deadline.
    func waitUntilEnded() async {
        let coordinator = self

        // NEW-P1-2: Wrap the entire Combine-based wait in a backstop timeout.
        // If the coordinator stalls with no state emission (task starvation, deadlock),
        // the for-await loop never evaluates the deadline check. This outer timeout
        // guarantees we always return within a bounded time.
        await withTaskGroup(of: Void.self) { group in
            // Backstop: cancel the group after the hard deadline.
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.endBackstopSeconds))
                guard !Task.isCancelled else { return }
                waitLog.warning("waitUntilEnded: backstop timeout (\(Self.endBackstopSeconds)s) — forcing cancel")
                await MainActor.run {
                    // The session may have finished just as the deadline hit;
                    // do not turn a delivered result into a timeout error.
                    switch coordinator.sessionState {
                    case .streaming, .finalizing:
                        coordinator.cancellationReason = .backstopTimeout
                        coordinator.cancelSession()
                    default:
                        break
                    }
                }
            }

            // Main wait: subscribe to state changes.
            group.addTask { @MainActor in
                let stream = AsyncStream<StreamingSessionState> { continuation in
                    let cancellable = coordinator.$sessionState.sink { state in
                        continuation.yield(state)
                    }
                    continuation.onTermination = { _ in
                        cancellable.cancel()
                    }
                }

                let deadline = Date().addingTimeInterval(Self.endDeadlineSeconds)
                var warningSent = false

                for await state in stream {
                    switch state {
                    case .done, .cancelled, .failed:
                        return
                    case .finalizing:
                        // Deliberately no success chime on the streaming path.
                        // Text appears progressively during recording, the stop
                        // sound already plays on hotkey release, and the pill's
                        // "Inserted" label covers the visual confirmation. A
                        // chime here either fires before the tail chunk's text
                        // (sound → text gap) or after the full-pass (text →
                        // sound gap, originally 1–15s) — both felt off in
                        // testing.
                        if !warningSent,
                           let startedAt = coordinator.finalizingStartedAt,
                           Date().timeIntervalSince(startedAt) >= StreamingTranscriptionCoordinator.fullPassWarningSeconds {
                            warningSent = true
                            waitLog.info("waitUntilEnded: full-pass taking >15s, user notified via pill")
                        }
                        if Date() >= deadline {
                            coordinator.cancelSession()
                            return
                        }
                    default:
                        break
                    }
                }
            }

            // Whichever finishes first cancels the other.
            await group.next()
            group.cancelAll()
        }
    }
}
