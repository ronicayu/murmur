import SwiftUI

struct FloatingPillView: View {
    let state: AppState
    let audioLevel: Float

    var body: some View {
        HStack(spacing: 8) {
            stateIcon
            stateText
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .frame(minWidth: 120)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pillAccessibilityLabel)
    }

    private var pillAccessibilityLabel: String {
        switch state {
        case .recording: return "Recording audio. Press Escape to cancel."
        case .transcribing: return "Transcribing audio"
        case .injecting: return "Inserting text"
        case .undoable(let text, _): return "Transcribed: \(text). Press Command Z to undo."
        case .error(let err): return "Error: \(err.localizedDescription)"
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
        case .transcribing:
            Text("Transcribing...")
                .font(.system(.caption, design: .rounded, weight: .medium))
        case .injecting:
            Text("Inserting text...")
                .font(.system(.caption, design: .rounded, weight: .medium))
        case .undoable(let text, _):
            HStack(spacing: 4) {
                Text(text.prefix(30))
                    .font(.system(.caption, design: .rounded))
                    .lineLimit(1)
            }
        case .error(let err):
            Text(err.localizedDescription)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .idle:
            EmptyView()
        }
    }
}

/// Window controller for the floating pill overlay.
final class FloatingPillController {
    private var window: NSWindow?
    private var hideTask: Task<Void, Never>?

    func show(state: AppState, audioLevel: Float = 0) {
        hideTask?.cancel()

        let pillView = FloatingPillView(state: state, audioLevel: audioLevel)
        let hostingView = NSHostingView(rootView: pillView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 40)

        if window == nil {
            let w = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
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
            window = w
        }

        window?.contentView = hostingView
        window?.setContentSize(hostingView.fittingSize)

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
