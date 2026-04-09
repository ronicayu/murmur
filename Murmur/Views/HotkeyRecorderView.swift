import SwiftUI
import Carbon
import HotKey

/// A view that captures a keyboard shortcut when focused.
struct HotkeyRecorderView: View {
    @Binding var key: Key
    @Binding var modifiers: NSEvent.ModifierFlags
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack(spacing: 4) {
                if isRecording {
                    Text("Press shortcut...")
                        .foregroundStyle(.orange)
                        .italic()
                } else {
                    Text(shortcutLabel)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    private var shortcutLabel: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Opt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        parts.append(key.description)
        return parts.joined(separator: " + ")
    }

    private func startRecording() {
        isRecording = true

        // Use both local (for when settings window is key) and global (for LSUIElement apps)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [self] event in
            guard let capturedKey = Key(carbonKeyCode: UInt32(event.keyCode)) else { return }

            let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
            guard !mods.isEmpty else { return }

            key = capturedKey
            modifiers = mods
            stopRecording()

            UserDefaults.standard.set(Int(event.keyCode), forKey: "hotkeyKeyCode")
            UserDefaults.standard.set(Int(mods.rawValue), forKey: "hotkeyModifiers")
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

// MARK: - Key description helper

extension Key {
    var description: String {
        switch self {
        case .space: return "Space"
        case .return: return "Return"
        case .tab: return "Tab"
        case .escape: return "Esc"
        case .delete: return "Delete"
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .d: return "D"
        case .e: return "E"
        case .f: return "F"
        case .g: return "G"
        case .h: return "H"
        case .i: return "I"
        case .j: return "J"
        case .k: return "K"
        case .l: return "L"
        case .m: return "M"
        case .n: return "N"
        case .o: return "O"
        case .p: return "P"
        case .q: return "Q"
        case .r: return "R"
        case .s: return "S"
        case .t: return "T"
        case .u: return "U"
        case .v: return "V"
        case .w: return "W"
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        default: return "Key(\(self.carbonKeyCode))"
        }
    }
}

// MARK: - Conflict Detection

struct HotkeyConflictDetector {
    /// Checks if Ctrl+Space is likely used for CJK input source switching.
    static func ctrlSpaceConflictsWithInputSources() -> Bool {
        guard let cfSources = TISCreateInputSourceList(nil, false) else { return false }
        let sources = cfSources.takeRetainedValue() as! [TISInputSource]

        let cjkLanguages: Set<String> = ["zh-Hans", "zh-Hant", "ja", "ko", "zh"]
        for source in sources {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { continue }
            let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as! [String]
            for lang in languages {
                let prefix = String(lang.prefix(2))
                if cjkLanguages.contains(prefix) || cjkLanguages.contains(lang) {
                    return true
                }
            }
        }
        return false
    }
}
