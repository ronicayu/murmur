import SwiftUI
import Combine

@main
struct MurmurApp: App {
    @StateObject private var modelManager: ModelManager
    @StateObject private var coordinator: AppCoordinator
    @StateObject private var historyService: TranscriptionHistoryService
    @State private var settingsWindow: NSWindow?
    @State private var onboardingWindow: NSWindow?
    @State private var transcriptionWindowController: TranscriptionWindowController?
    @State private var launched = false

    init() {
        let mm = ModelManager()
        let backend = mm.activeBackend
        let modelPath = mm.modelDirectory(for: backend)
        let ts: any TranscriptionServiceProtocol
        if backend == .onnx {
            ts = NativeTranscriptionService(modelPath: modelPath)
        } else {
            ts = TranscriptionService(modelPath: modelPath)
        }
        let coord = AppCoordinator(transcription: ts)
        // If the LID model is already on disk from a prior run, wire up the
        // identifier so the first autoDetect-enabled transcription doesn't
        // trigger a cold download.
        if let lidPath = mm.auxiliaryModelPath(.lidWhisperTiny) {
            coord.lid = LanguageIdentificationService(modelPath: lidPath)
        }
        _modelManager = StateObject(wrappedValue: mm)
        _coordinator = StateObject(wrappedValue: coord)
        _historyService = StateObject(wrappedValue: TranscriptionHistoryService())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                coordinator: coordinator,
                onOpenSettings: { showSettings() },
                onOpenTranscription: { showTranscriptionWindow() }
            )
        } label: {
            Label("Murmur", systemImage: menuBarIconName)
                .labelStyle(.titleAndIcon)
                .onAppear {
                    guard !launched else { return }
                    launched = true
                    // Initialise window controller (registers Cmd+Shift+T hotkey)
                    transcriptionWindowController = TranscriptionWindowController(
                        historyService: historyService,
                        coordinator: coordinator
                    )
                    // Scan for orphaned recordings from prior crash
                    historyService.scanAndRecoverOrphans()

                    if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showOnboarding()
                        }
                    }
                }
                .onReceive(modelManager.committedBackendChange) { newBackend in
                    // committedBackendChange only fires when setActiveBackend(_:) accepts
                    // the switch — never during an active download. This prevents the
                    // previous pattern (subscribing to $activeBackend) from tearing down
                    // the transcription service mid-download when a refused switch
                    // published a transient @Published willSet value.
                    let newPath = modelManager.modelDirectory(for: newBackend)
                    let newService: any TranscriptionServiceProtocol = newBackend == .onnx
                        ? NativeTranscriptionService(modelPath: newPath)
                        : TranscriptionService(modelPath: newPath)
                    coordinator.replaceTranscriptionService(newService)
                }
                .onReceive(modelManager.$state) { newState in
                    // Preload model immediately after download completes
                    if newState == .ready {
                        coordinator.preloadModelInBackground()
                    }
                }
                .onReceive(modelManager.$auxiliaryStates) { states in
                    // Attach / detach the LID service as the auxiliary model
                    // transitions between .ready and anything else (downloading,
                    // deleted, corrupt). Doing this via state subscription keeps
                    // the coordinator decoupled from ModelManager internals.
                    let lidReady = states[.lidWhisperTiny] == .ready
                        && modelManager.auxiliaryModelPath(.lidWhisperTiny) != nil
                    if lidReady, coordinator.lid == nil,
                       let path = modelManager.auxiliaryModelPath(.lidWhisperTiny) {
                        coordinator.lid = LanguageIdentificationService(modelPath: path)
                    } else if !lidReady, coordinator.lid != nil {
                        coordinator.lid = nil
                        // Reset the toggle so subsequent recordings don't fire
                        // the "Language model not installed" pill on every transcription.
                        UserDefaults.standard.set(false, forKey: "autoDetectLanguage")
                    }
                }
                // Listen for settings notification from Transcription window
                .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                    showSettings()
                }
        }
        .menuBarExtraStyle(.window)
    }

    private func showTranscriptionWindow() {
        transcriptionWindowController?.openOrFocus()
    }

    private var menuBarIconName: String {
        switch coordinator.state {
        case .recording: return "mic.fill"
        case .transcribing, .injecting: return "ellipsis.circle"
        case .error: return "exclamationmark.triangle"
        default: return "mic"
        }
    }

    private func showOnboarding() {
        if let existing = onboardingWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(
            coordinator: coordinator,
            modelManager: modelManager
        ) { [self] in
            onboardingWindow?.close()
            onboardingWindow = nil
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Murmur"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func showSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(coordinator: coordinator, modelManager: modelManager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
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
