import SwiftUI

private struct Pulsing: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
    }
}

extension View {
    /// A repeating pulse on a symbol, off when the user asked for reduced motion.
    func pulsing() -> some View {
        modifier(Pulsing())
    }
}
