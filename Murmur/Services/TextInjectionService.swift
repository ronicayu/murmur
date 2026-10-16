import AppKit
import os

enum InjectionMethod: Sendable, Equatable {
    case cgEvent
    case clipboard
}

protocol TextInjectionServiceProtocol {
    func inject(text: String) async throws -> InjectionMethod
}

final class TextInjectionService: TextInjectionServiceProtocol {
    private let log = Logger(subsystem: "com.murmur.app", category: "injection")

    func inject(text: String) async throws -> InjectionMethod {
        // Tier 1: Clipboard paste (most reliable — works with all apps)
        do {
            try await injectViaClipboard(text: text)
            log.info("Injected via clipboard (\(text.count) chars)")
            return .clipboard
        } catch {
            log.warning("Clipboard injection failed: \(error.localizedDescription), falling back to CGEvent")
        }

        // Tier 2: CGEvent keystrokes (fallback — event.post is void so failures are silent)
        try await injectViaCGEvent(text: text)
        log.info("Injected via CGEvent (\(text.count) chars)")
        return .cgEvent
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

    /// Post Cmd+V to the frontmost app.
    private static func postPasteKeystroke() throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            throw MurmurError.injectionFailed("Failed to create paste event")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    static let privateMarkers: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
    ]

    private static func restore(_ savedItems: [[(String, Data)]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        for itemTypes in savedItems {
            let item = NSPasteboardItem()
            for (typeStr, data) in itemTypes {
                item.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
            }
            pasteboard.writeObjects([item])
        }
    }

    /// `pasteboard` and `postPaste` are parameters so tests can use a private
    /// pasteboard and a paste that fails; the app always uses the defaults.
    func injectViaClipboard(
        text: String,
        pasteboard: NSPasteboard = .general,
        postPaste: () throws -> Void = TextInjectionService.postPasteKeystroke
    ) async throws {
        // Save current clipboard (all types per item) and change count
        let savedChangeCount = pasteboard.changeCount
        let savedItems = pasteboard.pasteboardItems?.map { item -> [(String, Data)] in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type.rawValue, data)
            }
        } ?? []

        // Set our text, marked (nspasteboard.org convention) as passing
        // through and private, so clipboard managers and history tools do
        // not keep a copy of every dictation. Adding types to the item does
        // not change `changeCount` again, which the restore below relies on.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        for marker in Self.privateMarkers { pasteboard.setData(Data(), forType: marker) }

        // Simulate Cmd+V
        do {
            try postPaste()
        } catch {
            // Nothing will read the clipboard, so give the user's content
            // back now instead of leaving the transcript there.
            Self.restore(savedItems, to: pasteboard)
            throw error
        }

        // Restore the user's clipboard asynchronously so inject() can return
        // immediately after the paste event is posted. Blocking here for 1.5 s
        // made AppCoordinator's "Inserted" pill lag 1.5 s behind the visible
        // text insertion.
        //
        // The sleep exists to give the target app time to consume the
        // clipboard BEFORE we overwrite it — in practice Cmd+V is handled
        // within a few tens of ms, but we keep the conservative wait.
        Task.detached {
            try? await Task.sleep(for: .milliseconds(1500))
            await MainActor.run {
                guard pasteboard.changeCount == savedChangeCount + 1 else {
                    // Clipboard was modified by the user or another app — skip restore.
                    return
                }
                Self.restore(savedItems, to: pasteboard)
            }
        }
    }
}
