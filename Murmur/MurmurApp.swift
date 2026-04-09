import SwiftUI

@main
struct MurmurApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var modelManager = ModelManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                coordinator: coordinator,
                onOpenSettings: { openSettingsWindow() }
            )
        } label: {
            menuBarIcon
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Murmur", id: "onboarding") {
            OnboardingView(
                coordinator: coordinator,
                modelManager: modelManager
            ) {
                // Close onboarding window
                NSApp.windows.first { $0.title == "Welcome to Murmur" }?.close()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Murmur Settings", id: "settings") {
            SettingsView(coordinator: coordinator, modelManager: modelManager)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    @ViewBuilder
    private var menuBarIcon: some View {
        switch coordinator.state {
        case .recording:
            Image(systemName: "mic.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.red)
        case .transcribing, .injecting:
            Image(systemName: "ellipsis.circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.orange)
        default:
            Image(systemName: "mic")
        }
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI will handle opening the window via the Window scene
        if let window = NSApp.windows.first(where: { $0.title == "Murmur Settings" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    init() {
        // Show onboarding on first launch
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title == "Welcome to Murmur" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}
