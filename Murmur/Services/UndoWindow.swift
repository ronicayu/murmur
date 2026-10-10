import AppKit

/// The few seconds after an insertion in which Murmur shows "Inserted" and
/// watches for the user's Cmd+Z. Owns the timer and the key monitor; what
/// the two events mean is the caller's business.
@MainActor
final class UndoWindow {
    private var timer: Task<Void, Never>?
    private var monitor: Any?

    /// Opens the window, replacing one that is still open.
    ///
    /// - Parameters:
    ///   - onUndoSeen: the user pressed Cmd+Z. A global monitor only
    ///     observes: the key press has already reached the target app and
    ///     undone the insertion, so the caller must not post another one.
    ///   - onExpire: `seconds` passed without `cancel()`.
    func open(
        seconds: TimeInterval = 5,
        onUndoSeen: @escaping @MainActor () -> Void,
        onExpire: @escaping @MainActor () -> Void
    ) {
        cancel()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  event.keyCode == 0x06 /* Z */ else { return }
            Task { @MainActor in onUndoSeen() }
        }
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.removeMonitor()
            onExpire()
        }
    }

    /// Ends the window: stops its timer and its Cmd+Z monitor.
    func cancel() {
        timer?.cancel()
        timer = nil
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
