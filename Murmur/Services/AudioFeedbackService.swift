import AppKit

/// Plays subtle system sounds for recording state changes.
/// Respects the user's sound effects preference.
final class AudioFeedbackService {
    /// Default playback volume for all feedback sounds. System sounds at 1.0 are
    /// noticeably loud relative to media playback; feedback should be unobtrusive.
    private static let defaultVolume: Float = 0.3

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? true
    }

    private func play(_ name: String) {
        guard isEnabled, let sound = NSSound(named: name) else { return }
        sound.volume = Self.defaultVolume
        sound.play()
    }

    func playStartRecording() {
        guard isEnabled else { return }
        // Tink is softer than the system beep and matches the stop sound family.
        play("Tink")
    }

    func playStopRecording() {
        play("Tink")
    }

    func playError() {
        play("Basso")
    }

    func playSuccess() {
        play("Pop")
    }
}
