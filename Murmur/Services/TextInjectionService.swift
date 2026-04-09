import AppKit
import os

enum InjectionMethod: Sendable, Equatable {
    case cgEvent
    case clipboard
}

protocol TextInjectionServiceProtocol {
    func inject(text: String) async throws -> InjectionMethod
    func undoLastInjection() async throws
}

final class TextInjectionService: TextInjectionServiceProtocol {
    private let log = Logger(subsystem: "com.murmur.app", category: "injection")
    private var lastInjectionMethod: InjectionMethod?

    func inject(text: String) async throws -> InjectionMethod {
        // Tier 1: Clipboard paste (most reliable — works with all apps)
        do {
            try await injectViaClipboard(text: text)
            lastInjectionMethod = .clipboard
            log.info("Injected via clipboard (\(text.count) chars)")
            return .clipboard
        } catch {
            log.warning("Clipboard injection failed: \(error.localizedDescription), falling back to CGEvent")
        }

        // Tier 2: CGEvent keystrokes (fallback — event.post is void so failures are silent)
        try await injectViaCGEvent(text: text)
        lastInjectionMethod = .cgEvent
        log.info("Injected via CGEvent (\(text.count) chars)")
        return .cgEvent
    }

    func undoLastInjection() async throws {
        guard lastInjectionMethod != nil else {
            log.info("No injection to undo")
            return
        }

        // Simulate Cmd+Z
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: false) else {
            throw MurmurError.injectionFailed("Failed to create undo event")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Tier 1: CGEvent Keystrokes

    private func injectViaCGEvent(text: String) async throws {
        let source = CGEventSource(stateID: .hidSystemState)

        for char in text {
            let str = String(char)
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
                throw MurmurError.injectionFailed("Failed to create CGEvent")
            }

            var unicodeChars = Array(str.utf16)
            event.keyboardSetUnicodeString(stringLength: unicodeChars.count, unicodeString: &unicodeChars)
            event.post(tap: .cghidEventTap)

            guard let upEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            upEvent.post(tap: .cghidEventTap)

            // Small delay to avoid overwhelming the target app
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - Tier 2: Clipboard Paste

    private func injectViaClipboard(text: String) async throws {
        let pasteboard = NSPasteboard.general

        // Save current clipboard (all types per item)
        let savedItems = pasteboard.pasteboardItems?.map { item -> [(String, Data)] in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type.rawValue, data)
            }
        } ?? []

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            throw MurmurError.injectionFailed("Failed to create paste event")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // Restore clipboard after delay
        try await Task.sleep(for: .milliseconds(1500))
        pasteboard.clearContents()
        for itemTypes in savedItems {
            let item = NSPasteboardItem()
            for (typeStr, data) in itemTypes {
                item.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
            }
            pasteboard.writeObjects([item])
        }
    }
}
