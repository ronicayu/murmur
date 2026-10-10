import AppKit
import HotKey

/// The persisted hotkey choice. The stored shape is what
/// `AppCoordinator.start()` reads at launch: a custom shortcut is in effect
/// only when both `hotkeyKeyCode` and `hotkeyModifiers` are present and the
/// key code is valid; anything else means Right Command.
enum HotkeyPreference {
    static let keyCodeKey = "hotkeyKeyCode"
    static let modifiersKey = "hotkeyModifiers"

    /// Shortcut offered when the user turns Right Command off and has not
    /// recorded one yet. Ctrl+Shift+Space is not a macOS system shortcut
    /// (Cmd+Space is Spotlight, Ctrl+Space and Ctrl+Opt+Space switch input
    /// sources, Cmd+Opt+Space is Finder search, Ctrl+Cmd+Space is the
    /// character viewer).
    static let defaultCustomKey: Key = .space
    static let defaultCustomModifiers: NSEvent.ModifierFlags = [.control, .shift]

    static func load(from defaults: UserDefaults = .standard) -> HotkeyTrigger {
        guard let keyCode = defaults.object(forKey: keyCodeKey) as? Int,
              let modsRaw = defaults.object(forKey: modifiersKey) as? UInt,
              let key = Key(carbonKeyCode: UInt32(keyCode)) else {
            return .rightCommand
        }
        return .keyCombo(key: key, modifiers: NSEvent.ModifierFlags(rawValue: modsRaw))
    }

    static func save(_ trigger: HotkeyTrigger, to defaults: UserDefaults = .standard) {
        switch trigger {
        case .rightCommand:
            defaults.removeObject(forKey: keyCodeKey)
            defaults.removeObject(forKey: modifiersKey)
        case .keyCombo(let key, let modifiers):
            defaults.set(Int(key.carbonKeyCode), forKey: keyCodeKey)
            defaults.set(Int(modifiers.rawValue), forKey: modifiersKey)
        }
    }
}
