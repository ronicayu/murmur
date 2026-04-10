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
    private var flagsMonitor: Any?
    private var escMonitor: Any?
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

    /// Programmatically emit an event (e.g., from onboarding record button).
    func emit(_ event: HotkeyEvent) {
        if event == .startRecording {
            lock.lock()
            isRecording = true
            lock.unlock()
        } else if event == .stopRecording {
            lock.lock()
            isRecording = false
            lock.unlock()
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

        // Esc to cancel — global so it works when any app is focused
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            self.lock.lock()
            let recording = self.isRecording
            self.lock.unlock()
            if recording && event.keyCode == 53 /* Esc */ {
                self.lock.lock()
                self.isRecording = false
                self.lock.unlock()
                self.continuation.yield(.cancelRecording)
            }
        }
    }

    /// Convenience for key+modifier combos (custom hotkey)
    func register(key: Key = .space, modifiers: NSEvent.ModifierFlags = .command) {
        register(trigger: .keyCombo(key: key, modifiers: modifiers))
    }

    func unregister() {
        hotKey = nil
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        flagsMonitor = nil
        escMonitor = nil
    }

    func setMode(_ mode: RecordingMode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    // MARK: - Right Command

    private func registerRightCommand() {
        // Right Command has keyCode 0x36 (54). Detect via flagsChanged events.
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            let isRightCmd = event.keyCode == 54 // 0x36 = right command
            guard isRightCmd else { return }

            let cmdDown = event.modifierFlags.contains(.command)

            if cmdDown && !self.rightCmdWasDown {
                // Right Cmd pressed
                self.rightCmdWasDown = true
                self.handleKeyDown()
            } else if !cmdDown && self.rightCmdWasDown {
                // Right Cmd released
                self.rightCmdWasDown = false
                self.handleKeyUp()
            }
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
        case .toggle:
            isRecording = !wasRecording
        case .hold:
            isRecording = true
        }
        let nowRecording = isRecording
        lock.unlock()

        if currentMode == .toggle {
            continuation.yield(nowRecording ? .startRecording : .stopRecording)
        } else if !wasRecording {
            continuation.yield(.startRecording)
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
            continuation.yield(.stopRecording)
        }
    }

    deinit {
        continuation.finish()
        unregister()
    }
}
