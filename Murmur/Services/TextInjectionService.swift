import AppKit
import os

/// Resolve the AX cursor offset (UTF-16 code units) of the currently focused element.
/// Returns the position after the selection (location + length), or nil if inaccessible.
/// Shared by AppCoordinator and StreamingTranscriptionCoordinator.
func resolveAXCursorOffset() -> Int? {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
    let axApp = AXUIElementCreateApplication(frontmost.processIdentifier)
    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
          let focused = focusedRef else { return nil }
    // swiftlint:disable:next force_cast
    let element = focused as! AXUIElement
    var selRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRef) == .success,
          let selValue = selRef else { return nil }
    var cfRange = CFRange()
    // swiftlint:disable:next force_cast
    guard AXValueGetValue(selValue as! AXValue, .cfRange, &cfRange) else { return nil }
    return cfRange.location + cfRange.length
}

enum InjectionMethod: Sendable, Equatable {
    case cgEvent
    case clipboard
}

protocol TextInjectionServiceProtocol {
    func inject(text: String) async throws -> InjectionMethod
    func undoLastInjection() async throws
}

final class TextInjectionService: TextInjectionServiceProtocol, StreamingTextInjectionProtocol {
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

    // MARK: - Streaming API (V3)

    /// Append text at the current cursor position without a preceding newline.
    ///
    /// Implementation: uses clipboard-paste (same as `inject`). The clipboard path
    /// is the most reliable cross-app method, and appending text at the cursor is
    /// exactly what Cmd+V does.
    ///
    /// - Parameter text: Text to append.
    func appendText(_ text: String) async throws {
        guard !text.isEmpty else { return }
        _ = try await inject(text: text)
        log.info("appendText: appended \(text.count) chars via streaming path")
    }

    /// Select a character range in the focused AX element and replace it with new text.
    ///
    /// Attempts via `kAXSelectedTextRangeAttribute` + `kAXSelectedTextAttribute`.
    ///
    /// **No clipboard fallback.** If the AX replace fails (e.g., Electron apps where
    /// `kAXSelectedTextRangeAttribute` set returns `.success` but does not move the cursor,
    /// or apps where AX is disabled entirely), the method logs a warning and returns without
    /// performing any replacement, leaving the streaming version intact.
    ///
    /// A clipboard-paste fallback would append the full-pass text on top of the existing
    /// streaming text, causing duplicate output (CR-P1-2, DA-P0-1).
    ///
    /// - Parameters:
    ///   - start: Zero-based AX character offset (UTF-16 code units).
    ///   - length: Number of UTF-16 code units to replace.
    ///   - text: Replacement text.
    func replaceRange(start: Int, length: Int, with text: String) async throws {
        guard length > 0 else {
            try await appendText(text)
            return
        }

        // DA-P0-1: Skip replacement for known-incompatible apps (e.g., Electron-based apps).
        if isFrontmostAppIncompatibleWithAXReplace() {
            log.warning("replaceRange: frontmost app does not support AX range replace (Electron/incompatible) — skipping replacement, streaming version preserved")
            return
        }

        let success = attemptAXReplaceRange(start: start, length: length, text: text)
        if success {
            log.info("replaceRange: AX replace succeeded (offset=\(start), length=\(length))")
            return
        }

        // CR-P1-2 / DA-P0-1: Do NOT fall back to clipboard paste. Pasting would append the
        // full-pass text after the existing streaming text, causing duplicate output.
        // Silently abandon the replacement; the streaming version is preserved.
        log.warning("replaceRange: AX replace unavailable — skipping replacement, streaming version preserved")
    }

    // MARK: - App Compatibility Check

    /// Returns true when the frontmost application is known to have broken AX range-replace
    /// behaviour (e.g., Electron-based apps where `kAXSelectedTextRangeAttribute` set
    /// returns `.success` but does not actually move the cursor).
    ///
    /// Detection heuristic: check the CFBundleExecutable or bundle identifier against a
    /// known-incompatible list. This is a best-effort guard; it does not cover every case.
    private func isFrontmostAppIncompatibleWithAXReplace() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }

        // Known Electron-based apps and other apps with broken AX replace.
        // Bundle IDs are stable across app updates; executable names are a fallback.
        let incompatibleBundleIDPrefixes: [String] = [
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.vscodium",
            "md.obsidian",
            "com.todesktop.",          // Electron app-builder prefix
            "com.github.GitHubDesktop",
            "com.figma.desktop",
            "com.slack.Slack",
            "com.tinyspeck.slackmacgap",
            "com.discord",
            "com.hnc.Discord",         // Discord PTB/Canary variants
            "com.spotify.client",
            "com.notion.id",
            "com.linear",
            "com.1password",
            "io.github.nicegram",
            "com.bitwarden.desktop",
        ]

        let bundleID = app.bundleIdentifier ?? ""
        for prefix in incompatibleBundleIDPrefixes {
            if bundleID.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    // MARK: - Private: AX Range Replace

    /// Attempt AX range selection + text replace. Returns true on success.
    private func attemptAXReplaceRange(start: Int, length: Int, text: String) -> Bool {
        guard let element = focusedAXElement() else { return false }

        var cfRange = CFRange(location: start, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return false }

        let selectErr = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
        guard selectErr == .success else {
            log.debug("replaceRange: kAXSelectedTextRangeAttribute set failed (\(selectErr.rawValue))")
            return false
        }

        let replaceErr = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if replaceErr == .success {
            return true
        }

        log.debug("replaceRange: kAXSelectedTextAttribute set failed (\(replaceErr.rawValue))")
        return false
    }

    private func focusedAXElement() -> AXUIElement? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(frontmost.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        // swiftlint:disable:next force_cast
        return (element as! AXUIElement)
    }

    // MARK: - Tier 2: Clipboard Paste

    private func injectViaClipboard(text: String) async throws {
        let pasteboard = NSPasteboard.general

        // Save current clipboard (all types per item) and change count
        let savedChangeCount = pasteboard.changeCount
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

        // Restore clipboard after delay, but only if nothing else has written to it
        try await Task.sleep(for: .milliseconds(1500))
        guard pasteboard.changeCount == savedChangeCount + 1 else {
            // Clipboard was modified by the user or another app — skip restore
            return
        }
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
