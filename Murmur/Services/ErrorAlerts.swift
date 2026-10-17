import AppKit

/// The blocking alerts for errors the user must acknowledge.
@MainActor
enum ErrorAlerts {
    /// Shows a critical error (model missing, disk full, …) and returns when
    /// the user has dismissed it.
    static func showCritical(_ err: MurmurError) {
        // Murmur is LSUIElement (menu-bar only); without an explicit activate,
        // runModal() can appear behind the focused app or ignore the event.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = err.alertTitle
        alert.informativeText = err.errorDescription ?? ""
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    /// Tells the user that `permission` is missing. True when they chose to
    /// fix it: System Settings for the microphone, the dictation set-up for
    /// Accessibility.
    static func askToOpenSettings(for permission: MurmurError.Permission) -> Bool {
        let text = permissionAlertText(for: permission)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: text.button)
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Accessibility is needed only by dictation: the alert says so, and
    /// does not suggest that transcribing recordings is blocked too.
    nonisolated static func permissionAlertText(
        for permission: MurmurError.Permission
    ) -> (title: String, message: String, button: String) {
        switch permission {
        case .accessibility:
            return ("Set Up Dictation",
                    "Dictation needs Accessibility access to type into other apps. Transcribing recordings works without it.",
                    "Set Up Dictation")
        case .microphone:
            return ("Microphone Access Needed",
                    "Murmur needs the microphone to hear you. Allow it in System Settings > Privacy & Security > Microphone.",
                    "Open Settings")
        case .inputMonitoring:
            return ("Input Monitoring Needed",
                    "Murmur needs Input Monitoring to hear its shortcut. Allow it in System Settings > Privacy & Security > Input Monitoring.",
                    "Open Settings")
        }
    }
}
