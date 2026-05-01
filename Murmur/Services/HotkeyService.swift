import AppKit
import Carbon
import HotKey

enum HotkeyEvent: Sendable {
    case startRecording
    case stopRecording
    case cancelRecording
}

enum RecordingMode: String, Sendable, CaseIterable {
    case toggle
    case hold
    /// Tap to start; recording auto-stops after a configurable trailing
    /// silence window detected by Silero VAD. Hotkey routing is identical
    /// to `.toggle` (tap to start, tap to stop manually). The auto-stop
    /// behaviour lives in `AudioService`, not here.
    case handsFree
}

enum HotkeyTrigger: Equatable, Sendable {
    case rightCommand
    case keyCombo(key: Key, modifiers: NSEvent.ModifierFlags)

    static func == (lhs: HotkeyTrigger, rhs: HotkeyTrigger) -> Bool {
        switch (lhs, rhs) {
        case (.rightCommand, .rightCommand): return true
        case (.keyCombo(let a, let b), .keyCombo(let c, let d)): return a == c && b == d
        default: return false
        }
    }
}

protocol HotkeyServiceProtocol: Sendable {
    var events: AsyncStream<HotkeyEvent> { get }
    func register(trigger: HotkeyTrigger)
    func unregister()
    func setMode(_ mode: RecordingMode)
}

final class HotkeyService: HotkeyServiceProtocol, @unchecked Sendable {
    let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation
    private var hotKey: HotKey?
    private var cancelHotKey: HotKey?
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var isRecording = false
    private var mode: RecordingMode = .toggle
    private var rightCmdWasDown = false
    private let lock = NSLock()

    init() {
        (events, continuation) = AsyncStream.makeStream(
            of: HotkeyEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    /// Sync the hotkey's internal `isRecording` flag back to false when a
    /// recording ends through a non-hotkey path (hands-free auto-stop or
    /// max-duration timeout). Without this, the next hotkey press toggles
    /// `isRecording` from true → false and emits `.stopRecording` (a
    /// no-op at the coordinator), so the user has to press the hotkey
    /// twice to start the next recording.
    func notifyRecordingStopped() {
        lock.lock()
        isRecording = false
        lock.unlock()
        unregisterCancelHotKey()
    }

    /// Programmatically emit an event (e.g., from onboarding record button, pill cancel button).
    func emit(_ event: HotkeyEvent) {
        switch event {
        case .startRecording:
            lock.lock()
            isRecording = true
            lock.unlock()
            registerCancelHotKey()
        case .stopRecording, .cancelRecording:
            lock.lock()
            isRecording = false
            lock.unlock()
            unregisterCancelHotKey()
        }
        continuation.yield(event)
    }

    func register(trigger: HotkeyTrigger = .rightCommand) {
        unregister()

        switch trigger {
        case .rightCommand:
            registerRightCommand()
        case .keyCombo(let key, let modifiers):
            registerKeyCombo(key: key, modifiers: modifiers)
        }
    }

    /// Register/unregister Esc as a Carbon hotkey only while recording is active.
    /// NSEvent global monitor for `.keyDown` is unreliable across macOS versions
    /// (sometimes returns a non-nil handle but never fires); Carbon hotkeys are not.
    private func registerCancelHotKey() {
        cancelHotKey = HotKey(key: .escape, modifiers: [])
        cancelHotKey?.keyDownHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let wasRecording = self.isRecording
            self.isRecording = false
            self.lock.unlock()
            if wasRecording {
                self.continuation.yield(.cancelRecording)
            }
            self.unregisterCancelHotKey()
        }
    }

    private func unregisterCancelHotKey() {
        cancelHotKey = nil
    }

    /// Convenience for key+modifier combos (custom hotkey)
    func register(key: Key = .space, modifiers: NSEvent.ModifierFlags = .command) {
        register(trigger: .keyCombo(key: key, modifiers: modifiers))
    }

    func unregister() {
        hotKey = nil
        cancelHotKey = nil
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        flagsMonitor = nil
        localFlagsMonitor = nil
    }

    func setMode(_ mode: RecordingMode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    // MARK: - Right Command

    private func registerRightCommand() {
        // Right Command has keyCode 0x36 (54). Detect via flagsChanged events.
        // Need both global (other apps) and local (Murmur focused) monitors.
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let isRightCmd = event.keyCode == 54 // 0x36 = right command
            guard isRightCmd else { return }

            let cmdDown = event.modifierFlags.contains(.command)

            self.lock.lock()
            let wasDown = self.rightCmdWasDown
            if cmdDown && !wasDown {
                self.rightCmdWasDown = true
                self.lock.unlock()
                self.handleKeyDown()
            } else if !cmdDown && wasDown {
                self.rightCmdWasDown = false
                self.lock.unlock()
                self.handleKeyUp()
            } else {
                self.lock.unlock()
            }
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    // MARK: - Key Combo

    private func registerKeyCombo(key: Key, modifiers: NSEvent.ModifierFlags) {
        hotKey = HotKey(key: key, modifiers: modifiers)
        hotKey?.keyDownHandler = { [weak self] in self?.handleKeyDown() }
        hotKey?.keyUpHandler = { [weak self] in self?.handleKeyUp() }
    }

    // MARK: - Shared handlers

    private func handleKeyDown() {
        lock.lock()
        let currentMode = mode
        let wasRecording = isRecording
        switch currentMode {
        case .toggle, .handsFree:
            isRecording = !wasRecording
        case .hold:
            isRecording = true
        }
        let nowRecording = isRecording
        lock.unlock()

        if nowRecording && !wasRecording {
            registerCancelHotKey()
        } else if !nowRecording && wasRecording {
            unregisterCancelHotKey()
        }

        switch currentMode {
        case .toggle, .handsFree:
            continuation.yield(nowRecording ? .startRecording : .stopRecording)
        case .hold:
            if !wasRecording {
                continuation.yield(.startRecording)
            }
        }
    }

    private func handleKeyUp() {
        lock.lock()
        let currentMode = mode
        let wasRecording = isRecording
        if currentMode == .hold && wasRecording {
            isRecording = false
        }
        lock.unlock()

        if currentMode == .hold && wasRecording {
            unregisterCancelHotKey()
            continuation.yield(.stopRecording)
        }
    }

    deinit {
        continuation.finish()
        unregister()
    }
}
