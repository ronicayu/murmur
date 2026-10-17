import AVFoundation

/// The system microphone mode the user chose for Murmur (Control Center →
/// Microphone Mode). Voice Isolation matters a lot in a noisy place: without
/// it, short words in the middle and at the end of a dictation get lost.
///
/// macOS keeps the mode per app and does not let an app set it. Murmur's
/// builds are signed ad hoc, so each update looks like a new app to macOS
/// and the mode goes back to Standard.
enum MicrophoneMode {
    static let reminderKey = "voiceIsolationReminder"
    static let remindedVersionKey = "voiceIsolationRemindedVersion"

    static var isVoiceIsolationOn: Bool {
        AVCaptureDevice.preferredMicrophoneMode == .voiceIsolation
    }

    /// Opens the Microphone Mode menu of Control Center. It lists the modes
    /// only while Murmur uses the microphone.
    static func showPicker() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    /// Whether to open the menu at this recording: Voice Isolation is off,
    /// the reminder is on, and it has not been offered for this version yet.
    /// Once per version, so a user who prefers Standard is asked again only
    /// after the next update, which is what resets the mode.
    static func shouldOffer(
        isVoiceIsolationOn: Bool, remindersOn: Bool, remindedVersion: String?, currentVersion: String
    ) -> Bool {
        !isVoiceIsolationOn && remindersOn && remindedVersion != currentVersion
    }
}
