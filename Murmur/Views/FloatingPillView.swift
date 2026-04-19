import SwiftUI

struct FloatingPillView: View {
    let state: AppState
    let audioLevel: Float
    let languageBadge: String?

    init(state: AppState, audioLevel: Float, languageBadge: String? = nil) {
        self.state = state
        self.audioLevel = audioLevel
        self.languageBadge = languageBadge
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 8) {
                stateIcon
                stateText
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .frame(minWidth: 120)

            if let badge = languageBadge, isRecordingState {
                LanguageBadgeView(text: badge)
                    .padding(.top, 4)
                    .padding(.trailing, 10)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pillAccessibilityLabel)
    }

    var isRecordingState: Bool {
        switch state {
        case .recording, .streaming: return true
        default: return false
        }
    }

    private var pillAccessibilityLabel: String {
        switch state {
        case .recording: return "Recording audio. Press Escape to cancel."
        case .streaming:
            return "Streaming voice input. Press Escape to cancel."
        case .transcribing: return "Transcribing audio"
        case .injecting: return "Inserting text"
        case .undoable: return "Inserted"
        case .error(let err): return "Error: \(err.shortMessage). \(err.errorDescription ?? "")"
        case .idle: return "Murmur idle"
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .scaleEffect(CGFloat(1.0 + audioLevel * 2))
                .animation(.easeInOut(duration: 0.1), value: audioLevel)
        case .streaming:
            // Pulsing wave icon signals live streaming
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .injecting:
            Image(systemName: "text.cursor")
                .font(.caption)
                .foregroundStyle(.blue)
        case .undoable:
            Image(systemName: "checkmark")
                .font(.caption.bold())
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var stateText: some View {
        switch state {
        case .recording:
            VStack(spacing: 1) {
                Text("Recording...")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                Text("Esc to cancel")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        case .streaming:
            VStack(spacing: 1) {
                Text("Listening...")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                Text("Esc to cancel")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        case .transcribing:
            Text("Transcribing...")
                .font(.system(.caption, design: .rounded, weight: .medium))
        case .injecting:
            Text("Inserting text...")
                .font(.system(.caption, design: .rounded, weight: .medium))
        case .undoable:
            Text("Inserted")
                .font(.system(.caption, design: .rounded, weight: .medium))
        case .error(let err):
            Text(err.shortMessage)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .idle:
            EmptyView()
        }
    }
}

/// Window controller for the floating pill overlay.
/// Uses a fixed-size window to avoid the NSHostingView.updateWindowContentSizeExtremaIfNecessary
/// crash (rdar://FB12345 — NSHostingView throws when updating constraints on a transitional window).
final class FloatingPillController {
    private var window: NSWindow?
    private var hostingView: NSHostingView<FloatingPillView>?
    private var hideTask: Task<Void, Never>?

    func show(state: AppState, audioLevel: Float = 0, languageBadge: String? = nil) {
        hideTask?.cancel()

        let pillView = FloatingPillView(state: state, audioLevel: audioLevel, languageBadge: languageBadge)

        if let hostingView {
            hostingView.rootView = pillView
        } else {
            let hv = NSHostingView(rootView: pillView)
            hv.frame = NSRect(x: 0, y: 0, width: 300, height: 50)
            // Disable automatic window resizing — this is the root cause of the crash.
            // NSHostingView.updateWindowContentSizeExtremaIfNecessary calls
            // _postWindowNeedsUpdateConstraints during display flush, which throws
            // when the window is in a transitional state (ordered out or mid-update).
            if #available(macOS 14.0, *) {
                hv.sizingOptions = []
            }
            hostingView = hv
        }

        if window == nil {
            let w = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 50),
                styleMask: [.nonactivatingPanel, .hudWindow],
                backing: .buffered,
                defer: false
            )
            w.level = .floating
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.isMovableByWindowBackground = false
            w.contentView = hostingView
            window = w
        }

        positionNearMenuBar()
        window?.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval = 0) {
        hideTask?.cancel()
        if delay > 0 {
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.window?.orderOut(nil)
            }
        } else {
            window?.orderOut(nil)
        }
    }

    private func positionNearMenuBar() {
        // Use screen with the mouse cursor (approximates "focused app screen")
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen = targetScreen else { return }

        let screenFrame = screen.visibleFrame
        let pillSize = window?.frame.size ?? NSSize(width: 200, height: 40)

        // Position: centered horizontally on target screen, just below menu bar
        let x = screenFrame.midX - pillSize.width / 2
        let y = screenFrame.maxY - pillSize.height - 8
        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
