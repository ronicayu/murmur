import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case microphone
    case accessibility
    case huggingfaceLogin
    case modelDownload
    case testTranscription
    case done
}

struct OnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel
    let onComplete: () -> Void

    init(coordinator: AppCoordinator, modelManager: ModelManager, onComplete: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: OnboardingViewModel(
            coordinator: coordinator,
            modelManager: modelManager
        ))
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            ProgressView(value: Double(viewModel.step.rawValue), total: Double(OnboardingStep.allCases.count - 1))
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
        .frame(width: 520, height: 440)
    }

    // MARK: - Step 1: Welcome

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
            Spacer()
            Button("Get Started") {
                viewModel.nextStep()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Step 2: Microphone

    private var microphoneStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Microphone Access")
                .font(.title2.bold())
            Text("Murmur needs your microphone to hear your voice.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if viewModel.micGranted {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Spacer()
            Button(viewModel.micGranted ? "Continue" : "Grant Access") {
                if viewModel.micGranted {
                    viewModel.nextStep()
                } else {
                    Task { await viewModel.requestMicrophone() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
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

    // MARK: - Step 4: HuggingFace Login

    private var huggingfaceLoginStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.indigo)
            Text("HuggingFace Login")
                .font(.title2.bold())
            Text("The speech model is hosted on HuggingFace and requires a free account to download.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                Label("1. Create a free account at huggingface.co", systemImage: "1.circle")
                Label("2. Visit the model page and request access", systemImage: "2.circle")
                Label("3. Click \"Login\" below to authenticate", systemImage: "3.circle")
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
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Download Speech Model")
                .font(.title2.bold())
            Text("Cohere Transcribe (~4 GB). This runs entirely on your Mac — no data leaves your device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if case .downloading = viewModel.modelManager.state {
                VStack(spacing: 8) {
                    ProgressView(value: viewModel.modelManager.downloadProgress)
                    HStack {
                        Text("\(Int(viewModel.modelManager.downloadProgress * 100))%")
                        Spacer()
                        Text(formatSpeed(viewModel.modelManager.downloadSpeed))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else if viewModel.modelManager.state == .ready {
                Label("Model downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if case .error(let msg) = viewModel.modelManager.state {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Spacer()

            if viewModel.modelManager.state == .ready {
                Button("Continue") {
                    viewModel.nextStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if case .downloading = viewModel.modelManager.state {
                Button("Cancel") {
                    viewModel.modelManager.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
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

                    Text("Press **Ctrl + Space** to start, speak, then press again to stop.")
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
                .disabled(viewModel.hotkeyTestResult == nil)
            }
        }
        .onAppear {
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
                    Label("**Ctrl + Space** — start / stop recording", systemImage: "keyboard")
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
