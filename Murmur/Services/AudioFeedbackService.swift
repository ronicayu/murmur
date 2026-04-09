import AppKit

/// Plays subtle system sounds for recording state changes.
/// Respects the user's sound effects preference.
final class AudioFeedbackService {
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? true
    }

    func playStartRecording() {
        guard isEnabled else { return }
        NSSound.beep() // System default; replace with custom sound later
    }

    func playStopRecording() {
        guard isEnabled else { return }
        // Use Tink for a softer stop sound
        if let sound = NSSound(named: "Tink") {
            sound.play()
        }
    }

    func playError() {
        guard isEnabled else { return }
        if let sound = NSSound(named: "Basso") {
            sound.play()
        }
    }

    func playSuccess() {
        guard isEnabled else { return }
        if let sound = NSSound(named: "Pop") {
            sound.play()
        }
    }
}
