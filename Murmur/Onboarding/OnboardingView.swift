import SwiftUI

/// Steps in order. Dictation's set-up (Accessibility, then trying it out)
/// comes after what both modes need (the microphone and the model), so a
/// user who only transcribes recordings can skip it.
enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case microphone
    case modelChoice
    case modelDownload
    case accessibility
    case testTranscription
    case done
}

struct OnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel
    let onComplete: () -> Void

    @State private var showCancelDownloadConfirmation = false
    /// The window hosting this view, so its close button can be told apart
    /// from any other window closing.
    @State private var hostWindow: NSWindow?

    /// Minimum downloaded bytes before the cancel confirmation dialog is shown.
    /// Mirrors the same constant in SettingsView — keep in sync.
    private static let cancelConfirmThresholdBytes: Int64 = 100 * 1_000_000 // 100 MB

    init(
        coordinator: AppCoordinator,
        modelManager: ModelManager,
        startAt: OnboardingStep = .welcome,
        onComplete: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: OnboardingViewModel(
            coordinator: coordinator,
            modelManager: modelManager,
            startAt: startAt
        ))
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar — maps actual step to visible progress (skipping modelChoice)
            ProgressView(value: Double(viewModel.visibleStepIndex), total: Double(viewModel.visibleStepCount - 1))
                .padding(.horizontal, 32)
                .padding(.top, 20)

            // Step content
            Group {
                switch viewModel.step {
                case .welcome:
                    welcomeStep
                case .microphone:
                    microphoneStep
                case .accessibility:
                    accessibilityStep
                case .modelChoice:
                    modelChoiceStep
                case .modelDownload:
                    modelDownloadStep
                case .testTranscription:
                    testTranscriptionStep
                case .done:
                    doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
        .frame(width: 520, height: 580)
        .background(HostWindowReader(window: $hostWindow))
        // The window is closable: without this, closing it at the test step
        // would leave the accessibility check skipped and the polls running.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let closing = note.object as? NSWindow, closing === hostWindow else { return }
            viewModel.teardown()
        }
    }

    // MARK: - Step 1: Welcome + Microphone (merged)

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
            Text("Welcome to Murmur")
                .font(.title.bold())
            Text("Speak into your Mac. Text appears.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Dictate into any app, or transcribe recordings and meetings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Local transcription. No cloud. Chinese + English.")
                .font(.body)
                .foregroundStyle(.tertiary)

            if viewModel.micGranted {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Spacer()
            Button(viewModel.micGranted ? "Get Started" : "Grant Microphone & Get Started") {
                if viewModel.micGranted {
                    viewModel.nextStep()
                } else {
                    Task {
                        await viewModel.requestMicrophone()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // microphone step is now merged into welcome — kept as empty redirect
    private var microphoneStep: some View {
        // This step is auto-skipped; kept for enum compatibility
        Color.clear.onAppear { viewModel.nextStep() }
    }

    // MARK: - Step 3: Accessibility

    private var accessibilityStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.purple)
            Text("Set Up Dictation")
                .font(.title2.bold())
            Text("Dictation types what you say into the app you are using. For that, Murmur needs Accessibility access in System Settings. Transcribing recordings and files does not need it.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if viewModel.accessibilityGranted {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("System Settings will open. Add Murmur to the Accessibility list.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
            if viewModel.accessibilityGranted {
                Button("Continue") {
                    viewModel.nextStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                VStack(spacing: 8) {
                    Button("Open System Settings") {
                        viewModel.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("I've already enabled it — Continue") {
                        viewModel.accessibilityGranted = true
                        viewModel.nextStep()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)

                    Button("Skip — I'll only transcribe recordings") {
                        viewModel.skipDictation()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .help("You can set up dictation later from the menu bar.")
                }
            }
        }
        .onAppear {
            // Check immediately — might already be granted
            viewModel.accessibilityGranted = AXIsProcessTrusted()
            if viewModel.accessibilityGranted {
                viewModel.nextStep()
            } else {
                viewModel.startPollingAccessibility()
            }
        }
    }

    // MARK: - Step 4: Model Choice

    /// There is one speech model, so there is nothing to choose; the view
    /// model always skips this step. Kept only so `OnboardingStep` stays stable.
    private var modelChoiceStep: some View {
        EmptyView()
    }

    // MARK: - Step 5: Model Download

    private var modelDownloadStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Download Speech Model")
                .font(.title2.bold())
            Text("Murmur needs its speech model (\(ModelBackend.qwen3.sizeDescription)).\nEverything runs on your Mac — no data leaves your device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if case .downloading(let progress, let speed) = viewModel.modelManager.state {
                VStack(spacing: 8) {
                    if progress >= 0 {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    HStack {
                        if !viewModel.modelManager.statusMessage.isEmpty {
                            Text(viewModel.modelManager.statusMessage)
                        }
                        Spacer()
                        if speed > 0 {
                            Text(formatSpeed(speed))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else if viewModel.modelManager.state == .ready {
                Label("Model downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if case .error(let msg) = viewModel.modelManager.state {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            // Show status message when not downloading (setup messages, errors, etc.)
            if case .downloading = viewModel.modelManager.state {
                // Already shown in the progress section above
            } else if !viewModel.modelManager.statusMessage.isEmpty {
                Text(viewModel.modelManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(viewModel.modelManager.statusMessage.hasPrefix("Error") ? .red : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer()

            if viewModel.modelManager.state == .ready {
                Button("Continue") {
                    viewModel.nextStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if case .downloading = viewModel.modelManager.state {
                Button("Cancel Download") {
                    if viewModel.modelManager.downloadedBytes >= Self.cancelConfirmThresholdBytes {
                        showCancelDownloadConfirmation = true
                    } else {
                        viewModel.modelManager.cancelDownload()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .confirmationDialog(
                    "Cancel Download?",
                    isPresented: $showCancelDownloadConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Cancel Download", role: .destructive) {
                        viewModel.modelManager.cancelDownload()
                    }
                    Button("Keep Downloading", role: .cancel) { }
                } message: {
                    let mb = viewModel.modelManager.downloadedBytes / 1_000_000
                    Text("You've downloaded \(mb) MB — cancelling will discard it.")
                }
            } else {
                Button("Download") {
                    Task { await viewModel.downloadModel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Step 5: Test Transcription

    private var testTranscriptionStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Try It Out")
                .font(.title2.bold())

            if !viewModel.hotkeyPracticeMode {
                // Step 5a: Record button (user hasn't learned the hotkey yet)
                VStack(spacing: 12) {
                    Text("Tap the button below and say something.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        viewModel.toggleTestRecording()
                    } label: {
                        Circle()
                            .fill(viewModel.coordinator.state == .recording ? .red : .blue)
                            .frame(width: 72, height: 72)
                            .overlay {
                                Image(systemName: viewModel.coordinator.state == .recording ? "stop.fill" : "mic.fill")
                                    .font(.title)
                                    .foregroundStyle(.white)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(viewModel.coordinator.state == .recording ? "Stop recording" : "Start recording")

                    if viewModel.coordinator.state == .recording {
                        Text("Recording... tap again to stop")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if viewModel.coordinator.state == .transcribing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Transcribing...")
                                .font(.caption)
                        }
                    }

                    transcriptionResult
                }
            } else {
                // Step 5b: Hotkey practice
                VStack(spacing: 12) {
                    Label("Now try the real shortcut", systemImage: "keyboard")
                        .font(.headline)

                    Text("Press **Right Command** to start, speak, then press again to stop.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if viewModel.coordinator.state == .recording {
                        HStack(spacing: 8) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text("Recording...")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else if viewModel.coordinator.state == .transcribing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Transcribing...")
                                .font(.caption)
                        }
                    }

                    transcriptionResult
                }
            }

            Spacer()

            if viewModel.hotkeyPracticeMode {
                Button("Continue") {
                    viewModel.nextStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.hotkeyTestResult == nil && viewModel.testResult == nil)
            }
        }
        .onAppear {
            viewModel.enableTestMode()
            viewModel.watchForTestResult()
        }
    }

    // MARK: - Step 6: Done

    @ViewBuilder
    private var transcriptionResult: some View {
        if let result = viewModel.testResult {
            VStack(spacing: 8) {
                Text(result)
                    .font(.body)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                if let lang = viewModel.testLanguage {
                    Text("Detected: \(lang == .chinese ? "Chinese" : "English")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Step 6: Done

    private var doneStep: some View {
        VStack(spacing: 24) {
            Spacer()

            if viewModel.dictationSkipped {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("You're All Set")
                    .font(.title.bold())

                VStack(alignment: .leading, spacing: 12) {
                    Label("**Cmd + Shift + T** — open Transcription to record or import audio", systemImage: "waveform")
                    Label("**Set Up Dictation…** in the menu bar — to dictate into other apps later", systemImage: "keyboard")
                }
                .font(.body)
                .foregroundStyle(.secondary)

                Text("Murmur lives in your menu bar and will launch at login.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if viewModel.hotkeyConflictDetected {
                // Ctrl+Space conflict detection for CJK users
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Hotkey Conflict Detected")
                        .font(.title2.bold())
                    Text("Ctrl + Space is used for input source switching on your Mac. Please choose a different shortcut.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HotkeyRecorderView(
                        key: $viewModel.customKey,
                        modifiers: $viewModel.customModifiers
                    )
                    .onChange(of: viewModel.customKey) { _, _ in
                        viewModel.customHotkeyDidChange()
                    }
                    .onChange(of: viewModel.customModifiers) { _, _ in
                        viewModel.customHotkeyDidChange()
                    }
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("You're All Set")
                    .font(.title.bold())

                VStack(alignment: .leading, spacing: 12) {
                    Label("**Right Command** — start / stop recording", systemImage: "keyboard")
                    Label("**Esc** — cancel recording", systemImage: "escape")
                    Label("**Cmd + Z** — undo last insertion", systemImage: "arrow.uturn.backward")
                }
                .font(.body)
                .foregroundStyle(.secondary)

                Text("Murmur lives in your menu bar and will launch at login.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
            Button("Start Using Murmur") {
                viewModel.completeOnboarding()
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.hotkeyConflictDetected)
        }
        .onAppear {
            if !viewModel.dictationSkipped { viewModel.checkHotkeyConflict() }
        }
    }

    private func formatSpeed(_ bytesPerSec: Int64) -> String {
        if bytesPerSec > 1_000_000 {
            return "\(bytesPerSec / 1_000_000) MB/s"
        } else if bytesPerSec > 1_000 {
            return "\(bytesPerSec / 1_000) KB/s"
        } else {
            return "\(bytesPerSec) B/s"
        }
    }
}

/// Reports the `NSWindow` a SwiftUI view ends up in.
private struct HostWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = ReportingView()
        view.onWindowChange = { newWindow in
            // Deferred: this fires during a view update.
            DispatchQueue.main.async { window = newWindow }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReportingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}
