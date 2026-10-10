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
    /// open System Settings.
    static func askToOpenSettings(for permission: MurmurError.Permission) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(permission.rawValue.capitalized) Permission Required"
        alert.informativeText = "Murmur needs \(permission.rawValue) access to work. Please grant it in System Settings."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Dismiss")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
