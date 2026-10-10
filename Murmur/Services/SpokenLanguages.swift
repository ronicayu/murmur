import Carbon.HIToolbox
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
    /// Whether Murmur has been tested with this language.
    let isTested: Bool

    var id: String { code }
}

/// The user's "Languages you speak" setting.
///
/// The speech model works out the spoken language by itself and cannot be
/// told which one to use. This setting therefore selects nothing; it tells
/// Murmur which writing systems to expect, so a transcript in an unexpected
/// script can be double-checked before it is typed.
enum SpokenLanguages {

    static let defaultsKey = "spokenLanguages"

    /// Every language Qwen3-ASR lists as supported. Only Chinese and English
    /// (and mixing the two) have been tested with Murmur.
    static let all: [SpokenLanguage] = [
        SpokenLanguage(code: "zh", name: "中文", scripts: [.han], isTested: true),
        SpokenLanguage(code: "en", name: "English", scripts: [], isTested: true),
        SpokenLanguage(code: "yue", name: "粵語", scripts: [.han], isTested: false),
        SpokenLanguage(code: "ja", name: "日本語", scripts: [.kana, .han], isTested: false),
        SpokenLanguage(code: "ko", name: "한국어", scripts: [.hangul, .han], isTested: false),
        SpokenLanguage(code: "fr", name: "Français", scripts: [], isTested: false),
        SpokenLanguage(code: "de", name: "Deutsch", scripts: [], isTested: false),
        SpokenLanguage(code: "es", name: "Español", scripts: [], isTested: false),
        SpokenLanguage(code: "pt", name: "Português", scripts: [], isTested: false),
        SpokenLanguage(code: "it", name: "Italiano", scripts: [], isTested: false),
        SpokenLanguage(code: "nl", name: "Nederlands", scripts: [], isTested: false),
        SpokenLanguage(code: "ru", name: "Русский", scripts: [.cyrillic], isTested: false),
        SpokenLanguage(code: "ar", name: "العربية", scripts: [.arabic], isTested: false),
        SpokenLanguage(code: "hi", name: "हिन्दी", scripts: [.devanagari], isTested: false),
        SpokenLanguage(code: "th", name: "ไทย", scripts: [.thai], isTested: false),
        SpokenLanguage(code: "vi", name: "Tiếng Việt", scripts: [], isTested: false),
        SpokenLanguage(code: "id", name: "Bahasa Indonesia", scripts: [], isTested: false),
        SpokenLanguage(code: "ms", name: "Bahasa Melayu", scripts: [], isTested: false),
        SpokenLanguage(code: "fil", name: "Filipino", scripts: [], isTested: false),
        SpokenLanguage(code: "tr", name: "Türkçe", scripts: [], isTested: false),
        SpokenLanguage(code: "fa", name: "فارسی", scripts: [.arabic], isTested: false),
        SpokenLanguage(code: "el", name: "Ελληνικά", scripts: [.greek], isTested: false),
        SpokenLanguage(code: "pl", name: "Polski", scripts: [], isTested: false),
        SpokenLanguage(code: "cs", name: "Čeština", scripts: [], isTested: false),
        SpokenLanguage(code: "hu", name: "Magyar", scripts: [], isTested: false),
        SpokenLanguage(code: "ro", name: "Română", scripts: [], isTested: false),
        SpokenLanguage(code: "mk", name: "Македонски", scripts: [.cyrillic], isTested: false),
        SpokenLanguage(code: "sv", name: "Svenska", scripts: [], isTested: false),
        SpokenLanguage(code: "da", name: "Dansk", scripts: [], isTested: false),
        SpokenLanguage(code: "fi", name: "Suomi", scripts: [], isTested: false),
    ]

    private static let byCode: [String: SpokenLanguage] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    // MARK: - Reading and writing the setting

    /// The user's languages, in the order of `all`. Never empty.
    static func current(defaults: UserDefaults = .standard) -> [String] {
        if let stored = defaults.stringArray(forKey: defaultsKey) {
            let known = normalised(stored)
            if !known.isEmpty { return known }
        }
        let initial = initialValue(
            legacySetting: defaults.string(forKey: "transcriptionLanguage"),
            systemLanguages: systemLanguageIdentifiers()
        )
        defaults.set(initial, forKey: defaultsKey)
        return initial
    }

    static func save(_ codes: [String], defaults: UserDefaults = .standard) {
        let known = normalised(codes)
        guard !known.isEmpty else { return }
        defaults.set(known, forKey: defaultsKey)
    }

    /// What the setting starts as.
    ///
    /// - A language pinned in the old "Language" picker carries over as the
    ///   only entry: that user told Murmur what they speak.
    /// - Otherwise (the old "Auto", or a fresh install) the list comes from
    ///   the Mac's preferred languages and keyboard layouts.
    /// - If none of those is a language the model supports, English.
    static func initialValue(legacySetting: String?, systemLanguages: [String]) -> [String] {
        if let pinned = legacySetting, pinned != "auto", let code = supportedCode(for: pinned) {
            return [code]
        }
        let fromSystem = normalised(systemLanguages.compactMap(supportedCode(for:)))
        return fromSystem.isEmpty ? ["en"] : fromSystem
    }

    /// Maps a locale or language identifier (`zh-Hans-CN`, `en_GB`, `yue-HK`)
    /// to one of the supported codes, or nil.
    static func supportedCode(for identifier: String) -> String? {
        let primary = identifier
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        switch primary {
        case "tl": return "fil"       // Tagalog is listed as Filipino
        case "nb", "no", "nn": return nil
        default: return byCode[primary] != nil ? primary : nil
        }
    }

    /// Known codes, de-duplicated, in the order of `all`.
    static func normalised(_ codes: [String]) -> [String] {
        let wanted = Set(codes)
        return all.map(\.code).filter(wanted.contains)
    }

    /// The Mac's preferred languages followed by the languages of its enabled
    /// keyboard layouts and input methods.
    static func systemLanguageIdentifiers() -> [String] {
        var identifiers = Locale.preferredLanguages
        let filter = [kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        if let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] {
            for source in sources {
                guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
                      let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String],
                      let primary = languages.first
                else { continue }
                identifiers.append(primary)
            }
        }
        return identifiers
    }

    // MARK: - Passing the setting to the engine

    /// The setting as the `language` argument of `TranscriptionServiceProtocol`,
    /// e.g. `"zh,en"`.
    static func hint(for codes: [String]) -> String {
        codes.joined(separator: ",")
    }

    /// Scripts to expect for a hint produced by `hint(for:)`. Latin is always
    /// expected. An empty or unrecognised hint expects Chinese and English,
    /// the languages Murmur is tested with.
    static func expectedScripts(forHint hint: String) -> Set<WritingScript> {
        let codes = hint.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let languages = codes.compactMap { byCode[$0] }
        var scripts: Set<WritingScript> = [.latin]
        if languages.isEmpty {
            scripts.insert(.han)
        } else {
            for language in languages { scripts.formUnion(language.scripts) }
        }
        return scripts
    }
}
