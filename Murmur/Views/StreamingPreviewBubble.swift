import SwiftUI

/// Live text for the streaming preview bubble.
final class StreamingPreviewModel: ObservableObject {
    @Published var text: String = ""

    /// The bubble has a fixed size, so only the most recent stretch of a long
    /// dictation is shown; the head is elided.
    static let maxVisibleCharacters = 150

    var visibleText: String {
        guard text.count > Self.maxVisibleCharacters else { return text }
        return "…" + text.suffix(Self.maxVisibleCharacters)
    }
}

/// Shows streamed text while the user is still speaking. Nothing is typed into
/// the target app until recording stops, when the final text is inserted once.
struct StreamingPreviewBubbleView: View {
    @ObservedObject var model: StreamingPreviewModel

    var body: some View {
        VStack(spacing: 0) {
            Text(model.visibleText)
                .font(.system(size: 15))
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            Spacer(minLength: 0)
        }
        .frame(width: StreamingPreviewController.size.width,
               height: StreamingPreviewController.size.height,
               alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dictation preview: \(model.text)")
    }
}

/// Window controller for the streaming preview bubble. Sits just below the
/// floating pill. Like the pill it uses a fixed-size, non-activating panel (see
/// `FloatingPillController` for why the size is fixed), and it ignores mouse
/// events so it never blocks the app underneath.
@MainActor
final class StreamingPreviewController {
    static let size = NSSize(width: 520, height: 170)
    /// Vertical space the pill occupies below the menu bar (its 50 pt window + margins).
    private static let pillClearance: CGFloat = 62

    private let model = StreamingPreviewModel()
    private var window: NSPanel?

    /// Replace the previewed text. An empty string hides the bubble.
    func update(_ text: String) {
        model.text = text
        guard !text.isEmpty else {
            window?.orderOut(nil)
            return
        }
        if window == nil {
            let hostingView = NSHostingView(rootView: StreamingPreviewBubbleView(model: model))
            hostingView.frame = NSRect(origin: .zero, size: Self.size)
            if #available(macOS 14.0, *) {
                hostingView.sizingOptions = []
            }
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.size),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = hostingView
            window = panel
        }
        if window?.isVisible != true {
            positionBelowPill()
            window?.orderFrontRegardless()
        }
    }

    func hide() {
        model.text = ""
        window?.orderOut(nil)
    }

    private func positionBelowPill() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        window?.setFrameOrigin(NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.maxY - Self.pillClearance - Self.size.height
        ))
    }
}
