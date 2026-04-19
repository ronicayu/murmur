import SwiftUI

// MARK: - LanguageBadge

/// Formats the resolved transcription language code for display in the floating pill.
/// - Fixed language: uppercase 2-letter ISO code, e.g. `EN`, `ZH`.
/// - Auto-resolved: same code with a trailing middle dot, e.g. `EN·`, `ZH·`.
/// - Unknown code: `??` (with dot if auto).
enum LanguageBadge {

    private static let supportedCodes: Set<String> = [
        "en", "zh", "ja", "ko", "fr", "de", "es", "pt", "it", "nl", "pl", "el", "ar", "vi",
    ]

    /// Returns the display string for a resolved language code.
    /// - Parameters:
    ///   - code: The resolved 2-letter ISO code (lowercase), e.g. `"en"`.
    ///   - isAuto: Whether the code was auto-resolved from the active input source.
    static func format(code: String, isAuto: Bool) -> String {
        let base = supportedCodes.contains(code) ? code.uppercased() : "??"
        return isAuto ? "\(base)·" : base
    }

    /// Convenience entry point that derives `isAuto` from the stored UserDefaults setting.
    /// - Parameters:
    ///   - resolvedCode: The code returned by `resolveTranscriptionLanguage()`.
    ///   - storedSetting: The raw value of the `transcriptionLanguage` UserDefault.
    static func badgeText(resolvedCode: String, storedSetting: String) -> String {
        format(code: resolvedCode, isAuto: storedSetting == "auto")
    }
}

// MARK: - BadgeView

/// A small, low-contrast label showing the active transcription language code.
struct LanguageBadgeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
    }
}
