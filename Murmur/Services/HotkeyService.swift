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

protocol HotkeyServiceProtocol: Sendable {
    var events: AsyncStream<HotkeyEvent> { get }
    func register(key: Key, modifiers: NSEvent.ModifierFlags)
    func unregister()
    func setMode(_ mode: RecordingMode)
}

/// All hotkey callbacks run on the main thread. Mutable state is
/// protected by `lock` for the rare case of cross-thread access.
final class HotkeyService: HotkeyServiceProtocol, @unchecked Sendable {
    let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation
    private var hotKey: HotKey?
    private var isRecording = false
    private var mode: RecordingMode = .toggle
    private var escMonitor: Any?
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

    func register(key: Key = .space, modifiers: NSEvent.ModifierFlags = .control) {
        unregister()

        hotKey = HotKey(key: key, modifiers: modifiers)
        hotKey?.keyDownHandler = { [weak self] in self?.handleKeyDown() }
        hotKey?.keyUpHandler = { [weak self] in self?.handleKeyUp() }

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording, event.keyCode == 53 /* Esc */ else { return event }
            self.isRecording = false
            self.continuation.yield(.cancelRecording)
            return nil
        }
    }

    func unregister() {
        hotKey = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    func setMode(_ mode: RecordingMode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

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
