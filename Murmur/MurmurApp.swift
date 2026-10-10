import SwiftUI
import Combine

@main
struct MurmurApp: App {
    @StateObject private var modelManager: ModelManager
    @StateObject private var coordinator: AppCoordinator
    @StateObject private var historyService: TranscriptionHistoryService
    @State private var settingsWindow: NSWindow?
    @State private var onboardingWindow: NSWindow?
    @State private var recentHistoryWindow: NSWindow?
    @State private var transcriptionWindowController: TranscriptionWindowController?
    @State private var launched = false

    init() {
        // One-shot migration: an earlier build defaulted `voiceProcessingEnabled`
        // to true, but Apple's voice-processing IO unit produces silent buffers
        // on some macOS device/route combinations (verified user report — the
        // VAD reported -200 dB peak, i.e. literal zeros, which fired
        // silenceDetected on every recording). Force it off once for users
        // who never explicitly toggled it; honour the choice afterwards.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "voiceProcessingMigrationV1") {
            defaults.set(false, forKey: "voiceProcessingEnabled")
            defaults.set(true, forKey: "voiceProcessingMigrationV1")
        }

        let mm = ModelManager()
        // One engine, one service, for the life of the app. It loads the model
        // lazily, so it can be created before the model has been downloaded.
        let ts = Qwen3TranscriptionService(modelDirectory: mm.modelDirectory(for: .qwen3))
        let coord = AppCoordinator(transcription: ts)

        // Local-only session metrics: JSON lines in Application Support, so
        // latency and streaming accuracy are visible while dogfooding.
        // Nothing leaves the machine.
        coord.metricsRecorder = SessionMetricsRecorder()

        // Silero VAD drives the post-record silence gate and hands-free
        // auto-stop in AudioService — gated by both the user toggle (`useVAD`)
        // and on-disk presence of the model file. ModelManager's init
        // downgrades the toggle when the model is missing, so the flag is
        // honest at launch.
        if mm.useVAD {
            Self.attachVAD(modelManager: mm, coord: coord)
        }



        // Wire the ASR-error correction engine chosen by Settings. Supports
        // swapping between Apple on-device and a local Ollama server — see
        // AppCoordinator.reconfigureCorrectionEngine for the decision logic.
        coord.reconfigureCorrectionEngine()

        _modelManager = StateObject(wrappedValue: mm)
        _coordinator = StateObject(wrappedValue: coord)
        _historyService = StateObject(wrappedValue: TranscriptionHistoryService())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                coordinator: coordinator,
                onOpenSettings: { showSettings() },
                onOpenTranscription: { showTranscriptionWindow() },
                onOpenRecentHistory: { showRecentHistory() }
            )
        } label: {
            Label("Murmur", systemImage: menuBarIconName)
                .labelStyle(.iconOnly)
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
                .onReceive(modelManager.committedUseVADChange) { isOn in
                    if isOn {
                        Self.attachVAD(modelManager: modelManager, coord: coordinator)
                    } else {
                        coordinator.setVadService(nil)
                    }
                }
                .onReceive(modelManager.$state) { newState in
                    // Preload the model as soon as a download completes, and
                    // release it when the user deletes it.
                    if newState == .ready {
                        coordinator.preloadModelInBackground()
                    } else if newState == .notDownloaded {
                        Task { await coordinator.transcription.unloadModel() }
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

    /// Hand AudioService a Silero VAD detector. Caller is responsible for
    /// gating on `mm.useVAD`. Safe to call repeatedly. If the model file is
    /// missing the call no-ops (the toggle should already be OFF in that case
    /// via the init downgrade logic).
    static func attachVAD(modelManager mm: ModelManager, coord: AppCoordinator) {
        let vadFile = mm.auxiliaryModelDirectory(.sileroVad)
            .appendingPathComponent("onnx/model.onnx")
        guard FileManager.default.fileExists(atPath: vadFile.path) else { return }
        if let svc = try? VadService(modelURL: vadFile) {
            coord.setVadService(svc)
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
        // If a Settings window already exists — visible OR hidden after a previous
        // close — reuse it instead of spawning a duplicate. With
        // `isReleasedWhenClosed = false` (set below on first open), the NSWindow
        // outlives every red-X close; calling makeKeyAndOrderFront brings it back
        // exactly as it was. Without this, fast clicks during the close animation
        // could leave two Settings windows on screen.
        if let existing = settingsWindow {
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

    private func showRecentHistory() {
        // Same reuse rule as showSettings — a closed-but-not-released window
        // gets re-shown rather than duplicated.
        if let existing = recentHistoryWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = RecentHistoryView(coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Recent Transcriptions"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        recentHistoryWindow = window
    }
}
