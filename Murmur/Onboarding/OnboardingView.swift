import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case microphone
    case accessibility
    case modelChoice
    case huggingfaceLogin
    case modelDownload
    case testTranscription
    case done
}

struct OnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel
    let onComplete: () -> Void

    @State private var showCancelDownloadConfirmation = false

    /// Minimum downloaded bytes before the cancel confirmation dialog is shown.
    /// Mirrors the same constant in SettingsView — keep in sync.
    private static let cancelConfirmThresholdBytes: Int64 = 100 * 1_000_000 // 100 MB

    init(coordinator: AppCoordinator, modelManager: ModelManager, onComplete: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: OnboardingViewModel(
            coordinator: coordinator,
            modelManager: modelManager
        ))
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar — maps actual step to visible progress (skipping modelChoice + huggingfaceLogin)
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
                case .huggingfaceLogin:
                    huggingfaceLoginStep
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
            Text("Accessibility Permission")
                .font(.title2.bold())
            Text("Murmur inserts text into your active app. This requires Accessibility access in System Settings.")
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

    private var modelChoiceStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Choose Speech Engine")
                .font(.title2.bold())
            Text("Pick how Murmur turns your voice into text.\nYou can switch anytime in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                ForEach(ModelBackend.allCases, id: \.self) { backend in
                    backendCard(backend)
                }
            }

            Spacer()
            Button("Continue") {
                viewModel.nextStep()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Step 5: HuggingFace Login

    private var huggingfaceLoginStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.indigo)
            Text("Free Account Required")
                .font(.title2.bold())
            Text("The High Quality engine is hosted on a platform called HuggingFace. You need a free account to download it.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                Label("1. Create a free account (opens in browser)", systemImage: "1.circle")
                Label("2. Request access to the model", systemImage: "2.circle")
                Label("3. Come back here and click \"Login\"", systemImage: "3.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if viewModel.hfLoggedIn {
                Label("Logged in to HuggingFace", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            if !viewModel.hfStatusMessage.isEmpty {
                Text(viewModel.hfStatusMessage)
                    .font(.caption)
                    .foregroundStyle(viewModel.hfStatusMessage.hasPrefix("Error") ? .red : .secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Open HuggingFace") {
                    NSWorkspace.shared.open(URL(string: "https://huggingface.co/CohereLabs/cohere-transcribe-03-2026")!)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if viewModel.hfLoggedIn {
                    Button("Continue") {
                        viewModel.nextStep()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("Login") {
                        Task { await viewModel.loginHuggingFace() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }

            Button("Skip (I'll set this up later)") {
                viewModel.nextStep()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .padding(.bottom, 4)
        }
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
            Text("\(viewModel.modelManager.activeBackend.shortName) engine (\(viewModel.modelManager.activeBackend.sizeDescription)).\nEverything runs on your Mac — no data leaves your device.")
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

            // Ctrl+Space conflict detection for CJK users
            if viewModel.hotkeyConflictDetected {
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
                        viewModel.hotkeyConflictDetected = false
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
            viewModel.checkHotkeyConflict()
        }
    }

    @ViewBuilder
    private func backendCard(_ backend: ModelBackend) -> some View {
        let isSelected: Bool = viewModel.modelManager.activeBackend == backend
        let isDownloaded: Bool = viewModel.modelManager.isModelDownloaded(for: backend)
        let switchLocked: Bool = viewModel.modelManager.isDownloadActive
        let isLocked: Bool = switchLocked && !isSelected
        let fillColor: Color = isSelected ? Color.accentColor.opacity(0.08) : Color.clear
        let strokeColor: Color = isSelected ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.2)

        Button {
            viewModel.selectBackend(backend)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: backendIcon(backend))
                    .font(.title2)
                    .foregroundStyle(backendColor(backend))
                    .frame(width: 32)

                backendCardContent(backend, isDownloaded: isDownloaded, isLocked: isLocked)

                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(fillColor))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(strokeColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        // Mirror the SettingsView.engineRow disabled pattern (CR-M1):
        // lock non-selected cards while a download or verification is running.
        // The setActiveBackend guard is still authoritative; this is defense-in-depth.
        .disabled(isLocked)
        .help(isLocked ? "Locked during download — wait for it to finish or cancel first." : "")
    }

    @ViewBuilder
    private func backendCardContent(_ backend: ModelBackend, isDownloaded: Bool, isLocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(backend.displayName)
                    .font(.headline)
                if backend == .onnx {
                    Text("Recommended")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue, in: Capsule())
                }
                if isDownloaded {
                    Text("Downloaded")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green, in: Capsule())
                }
            }
            Text(backend.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !isDownloaded {
                Text("Download: \(backend.sizeDescription)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if isLocked {
                Text("Locked during download")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private func backendIcon(_ backend: ModelBackend) -> String {
        switch backend {
        case .onnx: return "hare.fill"
        case .huggingface: return "wand.and.stars"
        case .whisper: return "waveform"
        case .fireRed: return "flame.fill"
        }
    }

    private func backendColor(_ backend: ModelBackend) -> Color {
        switch backend {
        case .onnx: return .blue
        case .huggingface: return .purple
        case .whisper: return .orange
        case .fireRed: return .red
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
