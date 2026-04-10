import AppKit
import SwiftUI
import Carbon
import os

// MARK: - TranscriptionWindowController
//
// Manages the lifecycle of the main Audio Transcription window.
//
// Responsibilities:
// - Open / focus the window
// - Register Cmd+Shift+T global hotkey
// - Switch activationPolicy .accessory ↔ .regular when window opens/closes
// - NSWindowDelegate to detect close event

@MainActor
final class TranscriptionWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var globalHotkeyMonitor: Any?
    private static let log = Logger(subsystem: "com.murmur.app", category: "transcription-window")

    // Dependencies passed through to the SwiftUI view
    private let historyService: TranscriptionHistoryService
    private let coordinator: AppCoordinator

    init(historyService: TranscriptionHistoryService, coordinator: AppCoordinator) {
        self.historyService = historyService
        self.coordinator = coordinator
        super.init()
        registerGlobalHotkey()

        // Listen for notification-based open requests (from menu bar popover)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenRequest),
            name: .openTranscriptionWindow,
            object: nil
        )
    }

    deinit {
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Open / Focus

    func openOrFocus() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = TranscriptionWindowView(
            historyService: historyService,
            coordinator: coordinator
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Audio Transcription"
        win.contentView = NSHostingView(rootView: contentView)
        win.setFrameAutosaveName("AudioTranscriptionWindow")
        win.minSize = NSSize(width: 640, height: 480)
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.makeKeyAndOrderFront(nil)

        // Switch to .regular so Dock icon appears
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
        Self.log.info("Transcription window opened")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // C3: only revert to .accessory if no other visible window remains.
        // If onboarding or settings window is still open, the user is still
        // interacting with a regular window — hiding the Dock icon would be jarring.
        let closingWindow = notification.object as? NSWindow
        let hasOtherVisibleWindow = NSApp.windows.contains { win in
            win !== closingWindow && win.isVisible
        }
        guard !hasOtherVisibleWindow else {
            Self.log.info("Transcription window closed — other windows visible, keeping .regular")
            return
        }
        NSApp.setActivationPolicy(.accessory)
        Self.log.info("Transcription window closed — reverted to .accessory")
    }

    // MARK: - Hotkey (Cmd+Shift+T)

    private func registerGlobalHotkey() {
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard
                event.modifierFlags.contains([.command, .shift]),
                event.charactersIgnoringModifiers?.lowercased() == "t"
            else { return }
            Task { @MainActor [weak self] in
                self?.openOrFocus()
            }
        }
    }

    @objc private func handleOpenRequest() {
        openOrFocus()
    }
}
