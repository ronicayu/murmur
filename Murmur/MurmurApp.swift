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
        let backend = mm.activeBackend
        let modelPath = mm.modelDirectory(for: backend)
        let ts: any TranscriptionServiceProtocol
        if backend == .onnx {
            ts = NativeTranscriptionService(modelPath: modelPath)
        } else {
            ts = TranscriptionService(modelPath: modelPath)
        }
        let coord = AppCoordinator(transcription: ts)
        coord.modelManager = mm

        // Build FireRed service if either route is active and the model is on disk.
        if Self.shouldHaveFireRed(modelManager: mm) {
            if let svc = try? FireRedTranscriptionService(modelDirectory: mm.modelDirectory(for: .fireRed)) {
                coord.setFireRedService(svc, modelDirectory: mm.modelDirectory(for: .fireRed))
            }
        }

        // Build ASR-punctuation service if the toggle is on and the aux model is on disk.
        if mm.useASRPunctuation {
            if let svc = try? ASRPunctuationService(
                modelDirectory: mm.auxiliaryModelDirectory(.punctuationCT)
            ) {
                coord.setASRPunctuationService(svc)
            }
        }

        // Wire Silero VAD into all four consumers — gated by both the
        // user toggle (`useVAD`) and on-disk presence of the model file.
        // The toggle is the source of truth; `init`'s downgrade-on-
        // missing-model logic in ModelManager keeps the flag honest at
        // launch.
        //
        // Consumers:
        //   • AudioService — one shared `VadService` for the post-record
        //     silence gate and hands-free auto-stop.
        //   • StreamingCoordinator — gets only the model URL and builds
        //     a fresh `VadService` per session so streaming chunking has
        //     its own detector state.
        //   • NativeTranscriptionService — long-audio chunking +
        //     paragraph breaks. Python-subprocess backends keep the
        //     legacy 30 s + 5 s overlap path.
        if mm.useVAD {
            Self.attachVAD(modelManager: mm, coord: coord, ts: ts)
        }

        // Whisper-tiny LID was removed in favour of Cohere-echo retry — see
        // AppCoordinator.transcribeWithAutoDetectIfNeeded. The on-disk
        // ~/Library/Application Support/Murmur/Models-LID/ directory is no
        // longer read by the app; users can delete it manually to reclaim
        // ~40 MB. We do not auto-delete to avoid surprising data loss.

        // v0.3.0: rule-based cleanup service — always available, no download gate.
        coord.cleanup = PunctuationCleanupService()

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

                    // Re-attach VAD across consumers (gated on the toggle)
                    // so file/long-audio chunking keeps Phase 5 behaviour
                    // across backend switches. The freshly-built service
                    // doesn't share state with the prior one, so we have
                    // to push the URL again.
                    if modelManager.useVAD {
                        Self.attachVAD(
                            modelManager: modelManager,
                            coord: coordinator,
                            ts: newService
                        )
                    }

                    if Self.shouldHaveFireRed(modelManager: modelManager) {
                        if let svc = try? FireRedTranscriptionService(
                            modelDirectory: modelManager.modelDirectory(for: .fireRed)
                        ) {
                            coordinator.setFireRedService(
                                svc, modelDirectory: modelManager.modelDirectory(for: .fireRed)
                            )
                        }
                    } else {
                        coordinator.setFireRedService(nil, modelDirectory: nil)
                    }
                }
                .onReceive(modelManager.committedUseFireRedChange) { _ in
                    if Self.shouldHaveFireRed(modelManager: modelManager) {
                        if let svc = try? FireRedTranscriptionService(
                            modelDirectory: modelManager.modelDirectory(for: .fireRed)
                        ) {
                            coordinator.setFireRedService(
                                svc, modelDirectory: modelManager.modelDirectory(for: .fireRed)
                            )
                        }
                    } else {
                        coordinator.setFireRedService(nil, modelDirectory: nil)
                    }
                }
                .onReceive(modelManager.committedUseVADChange) { isOn in
                    if isOn {
                        Self.attachVAD(
                            modelManager: modelManager,
                            coord: coordinator,
                            ts: coordinator.transcription
                        )
                    } else {
                        Self.detachVAD(
                            coord: coordinator,
                            ts: coordinator.transcription
                        )
                    }
                }
                .onReceive(modelManager.committedUseASRPunctuationChange) { isOn in
                    if isOn {
                        if let svc = try? ASRPunctuationService(
                            modelDirectory: modelManager.auxiliaryModelDirectory(.punctuationCT)
                        ) {
                            coordinator.setASRPunctuationService(svc)
                        }
                    } else {
                        coordinator.setASRPunctuationService(nil)
                    }
                }
                .onReceive(modelManager.$state) { newState in
                    // Preload model immediately after download completes
                    if newState == .ready {
                        coordinator.preloadModelInBackground()
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

    /// Wire the Silero VAD service into all four consumers. Caller is
    /// responsible for gating on `mm.useVAD`. Safe to call repeatedly.
    /// If the model file is missing the call no-ops (the toggle should
    /// already be OFF in that case via the init downgrade logic).
    static func attachVAD(
        modelManager mm: ModelManager,
        coord: AppCoordinator,
        ts: any TranscriptionServiceProtocol
    ) {
        let vadFile = mm.auxiliaryModelDirectory(.sileroVad)
            .appendingPathComponent("onnx/model.onnx")
        guard FileManager.default.fileExists(atPath: vadFile.path) else { return }
        if let svc = try? VadService(modelURL: vadFile) {
            coord.setVadService(svc)
        }
        coord.streamingCoordinator?.setVadModelURL(vadFile)
        if let native = ts as? NativeTranscriptionService {
            Task { await native.setVadModelURL(vadFile) }
        }
    }

    /// Tear down VAD wiring across all four consumers, returning each to
    /// its pre-VAD behaviour. Used when the user toggles VAD off.
    static func detachVAD(
        coord: AppCoordinator,
        ts: any TranscriptionServiceProtocol
    ) {
        coord.setVadService(nil)
        coord.streamingCoordinator?.setVadModelURL(nil)
        if let native = ts as? NativeTranscriptionService {
            Task { await native.setVadModelURL(nil) }
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

    /// FireRed should be loaded if (a) the FireRed backend is active, OR
    /// (b) the cross-backend toggle is on. Both require the FireRed model
    /// to be present on disk — we re-check at construction time to guard
    /// against stale UserDefaults.
    private static func shouldHaveFireRed(modelManager mm: ModelManager) -> Bool {
        let modelExists = FileManager.default.fileExists(
            atPath: mm.modelDirectory(for: .fireRed).path
        )
        guard modelExists else { return false }
        if mm.activeBackend == .fireRed { return true }
        if mm.useFireRedForChinese && mm.activeBackend == .onnx {
            return true
        }
        return false
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
