import SwiftUI

@main
struct MurmurApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var modelManager = ModelManager()
    @State private var settingsWindow: NSWindow?

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                coordinator: coordinator,
                onOpenSettings: { showSettings() }
            )
        } label: {
            Label("Murmur", systemImage: menuBarIconName)
                .labelStyle(.titleAndIcon)
        }
    }

    private var menuBarIconName: String {
        switch coordinator.state {
        case .recording: return "mic.fill"
        case .transcribing, .injecting: return "ellipsis.circle"
        case .error: return "exclamationmark.triangle"
        default: return "mic"
        }
    }

    private func showSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(coordinator: coordinator, modelManager: modelManager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Murmur Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
