import Foundation

/// Writing systems the speech model can produce, as far as Murmur needs to
/// tell them apart.
enum WritingScript: String, Sendable, CaseIterable {
    case latin, han, kana, hangul, cyrillic, arabic, greek, thai, devanagari, other

    /// Script of a letter, or nil for digits, punctuation, spaces and symbols,
    /// which belong to no script in particular.
    static func of(_ scalar: Unicode.Scalar) -> WritingScript? {
        guard CharacterSet.letters.contains(scalar) else { return nil }
        switch scalar.value {
        case 0x0000...0x024F, 0x1E00...0x1EFF, 0xFF21...0xFF5A: return .latin
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return .han
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .kana
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return .hangul
        case 0x0400...0x052F: return .cyrillic
        case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
        case 0x0E00...0x0E7F: return .thai
        case 0x0900...0x097F: return .devanagari
        default: return .other
        }
    }

    /// How many letters of each script `text` contains.
    static func counts(in text: String) -> [WritingScript: Int] {
        var counts: [WritingScript: Int] = [:]
        for scalar in text.unicodeScalars {
            if let script = of(scalar) { counts[script, default: 0] += 1 }
        }
        return counts
    }
}

/// A language the speech model accepts.
struct SpokenLanguage: Identifiable, Equatable, Sendable {
    /// BCP-47 primary subtag (`yue` for Cantonese).
    let code: String
    /// The language's own name, as shown in Settings.
    let name: String
    /// Scripts its text is written in, besides Latin, which is always
    /// accepted (names, numbers and borrowed words appear in every language).
    let scripts: Set<WritingScript>

    var id: String { code }
}

/// The user's "Languages you speak" setting.
///
/// The speech model works out the spoken language by itself, and the
/// sherpa-onnx API Murmur runs it through has no way to restrict it to some
/// languages (nor does it report which one it chose). This setting therefore
/// selects nothing in the model; it tells Murmur which writing systems to
/// expect, so a transcript in an unexpected script can be double-checked
/// before it is typed.
///
/// Every language is on by default, which expects everything and checks
/// nothing. Narrowing the list is how a user opts in to the check.
enum SpokenLanguages {

    static let defaultsKey = "spokenLanguages"

    /// The languages Murmur offers: those of Qwen3-ASR's 30 that it transcribes
    /// acceptably in this configuration (0.6B, int8, no language forcing).
    ///
    /// Measured on 30 FLEURS validation clips per language, eleven languages
    /// came out at 40–75% word error — often a phonetic approximation, or the
    /// words of a neighbouring language — and are left out: Filipino, Polish,
    /// Swedish, Greek, Czech, Romanian, Finnish, Hungarian, Danish, Persian
    /// and Macedonian. The model still transcribes them if spoken; Murmur
    /// just does not present them as supported. Figures are in the README.
    static let all: [SpokenLanguage] = [
        SpokenLanguage(code: "zh", name: "中文", scripts: [.han]),
        SpokenLanguage(code: "en", name: "English", scripts: []),
        SpokenLanguage(code: "yue", name: "粵語", scripts: [.han]),
        SpokenLanguage(code: "ja", name: "日本語", scripts: [.kana, .han]),
        SpokenLanguage(code: "ko", name: "한국어", scripts: [.hangul, .han]),
        SpokenLanguage(code: "fr", name: "Français", scripts: []),
        SpokenLanguage(code: "de", name: "Deutsch", scripts: []),
        SpokenLanguage(code: "es", name: "Español", scripts: []),
        SpokenLanguage(code: "pt", name: "Português", scripts: []),
        SpokenLanguage(code: "it", name: "Italiano", scripts: []),
        SpokenLanguage(code: "nl", name: "Nederlands", scripts: []),
        SpokenLanguage(code: "ru", name: "Русский", scripts: [.cyrillic]),
        SpokenLanguage(code: "ar", name: "العربية", scripts: [.arabic]),
        SpokenLanguage(code: "hi", name: "हिन्दी", scripts: [.devanagari]),
        SpokenLanguage(code: "th", name: "ไทย", scripts: [.thai]),
        SpokenLanguage(code: "vi", name: "Tiếng Việt", scripts: []),
        SpokenLanguage(code: "id", name: "Bahasa Indonesia", scripts: []),
        SpokenLanguage(code: "ms", name: "Bahasa Melayu", scripts: []),
        SpokenLanguage(code: "tr", name: "Türkçe", scripts: []),
    ]

    private static let byCode: [String: SpokenLanguage] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    // MARK: - Reading and writing the setting

    /// The user's languages, in the order of `all`. Never empty. All of them
    /// until the user narrows the list — and because that default is not
    /// written back, a language added to `all` later is included too.
    static func current(defaults: UserDefaults = .standard) -> [String] {
        if let stored = defaults.stringArray(forKey: defaultsKey) {
            let known = normalised(stored)
            if !known.isEmpty { return known }
        }
        return all.map(\.code)
    }

    static func save(_ codes: [String], defaults: UserDefaults = .standard) {
        let known = normalised(codes)
        guard !known.isEmpty else { return }
        if known.count == all.count {
            // Back to the default: stop pinning the list.
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(known, forKey: defaultsKey)
        }
    }

    /// Known codes, de-duplicated, in the order of `all`.
    static func normalised(_ codes: [String]) -> [String] {
        let wanted = Set(codes)
        return all.map(\.code).filter(wanted.contains)
    }

    // MARK: - Passing the setting to the engine

    /// The setting as the `language` argument of `TranscriptionServiceProtocol`,
    /// e.g. `"zh,en"`.
    static func hint(for codes: [String]) -> String {
        codes.joined(separator: ",")
    }

    /// Scripts to expect for a hint produced by `hint(for:)`. Latin is always
    /// expected. A hint that names no known language restricts nothing: every
    /// script is expected.
    static func expectedScripts(forHint hint: String) -> Set<WritingScript> {
        let codes = hint.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let languages = codes.compactMap { byCode[$0] }
        var scripts: Set<WritingScript> = [.latin]
        guard !languages.isEmpty else { return Set(WritingScript.allCases) }
        for language in languages { scripts.formUnion(language.scripts) }
        return scripts
    }
}
