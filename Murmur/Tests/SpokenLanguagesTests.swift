import XCTest
@testable import Murmur

final class SpokenLanguagesTests: XCTestCase {

    // MARK: - The language list

    func test_codesAreUnique() {
        let codes = SpokenLanguages.all.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    func test_onlyChineseAndEnglishAreMarkedTested() {
        XCTAssertEqual(SpokenLanguages.all.filter(\.isTested).map(\.code), ["zh", "en"])
    }

    // MARK: - Identifiers from macOS

    func test_supportedCode_stripsRegionAndScript() {
        XCTAssertEqual(SpokenLanguages.supportedCode(for: "zh-Hans-CN"), "zh")
        XCTAssertEqual(SpokenLanguages.supportedCode(for: "en_GB"), "en")
        XCTAssertEqual(SpokenLanguages.supportedCode(for: "yue-HK"), "yue")
        XCTAssertEqual(SpokenLanguages.supportedCode(for: "JA"), "ja")
    }

    func test_supportedCode_mapsTagalogToFilipino() {
        XCTAssertEqual(SpokenLanguages.supportedCode(for: "tl-PH"), "fil")
    }

    func test_supportedCode_isNilForLanguagesTheModelLacks() {
        XCTAssertNil(SpokenLanguages.supportedCode(for: "nb-NO"))
        XCTAssertNil(SpokenLanguages.supportedCode(for: "he-IL"))
        XCTAssertNil(SpokenLanguages.supportedCode(for: ""))
    }

    func test_normalised_dropsUnknownAndDuplicateCodes_andUsesListOrder() {
        XCTAssertEqual(SpokenLanguages.normalised(["ja", "xx", "en", "zh", "en"]), ["zh", "en", "ja"])
    }

    // MARK: - First value of the setting

    func test_initialValue_freshInstallUsesTheMacsLanguages() {
        XCTAssertEqual(
            SpokenLanguages.initialValue(legacySetting: nil, systemLanguages: ["en-US", "zh-Hans-CN", "ja-JP"]),
            ["zh", "en", "ja"]
        )
    }

    func test_initialValue_oldAutoSettingUsesTheMacsLanguages() {
        XCTAssertEqual(
            SpokenLanguages.initialValue(legacySetting: "auto", systemLanguages: ["zh-Hans", "en"]),
            ["zh", "en"]
        )
    }

    func test_initialValue_pinnedLanguageCarriesOverAlone() {
        XCTAssertEqual(
            SpokenLanguages.initialValue(legacySetting: "ja", systemLanguages: ["en-US", "zh-Hans"]),
            ["ja"]
        )
    }

    func test_initialValue_fallsBackToEnglishWhenNothingIsSupported() {
        XCTAssertEqual(SpokenLanguages.initialValue(legacySetting: nil, systemLanguages: ["he-IL", "nb"]), ["en"])
        XCTAssertEqual(SpokenLanguages.initialValue(legacySetting: nil, systemLanguages: []), ["en"])
    }

    // MARK: - Stored setting

    private func makeDefaults() -> UserDefaults {
        let name = "SpokenLanguagesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func test_current_returnsWhatWasSaved() {
        let defaults = makeDefaults()
        SpokenLanguages.save(["en", "ko"], defaults: defaults)
        XCTAssertEqual(SpokenLanguages.current(defaults: defaults), ["en", "ko"])
    }

    func test_current_migratesAPinnedLegacyLanguageOnce() {
        let defaults = makeDefaults()
        defaults.set("zh", forKey: "transcriptionLanguage")
        XCTAssertEqual(SpokenLanguages.current(defaults: defaults), ["zh"])
        XCTAssertEqual(defaults.stringArray(forKey: SpokenLanguages.defaultsKey), ["zh"],
                       "the migrated value is stored so later reads do not depend on the old key")
    }

    func test_save_ignoresAnEmptySelection() {
        let defaults = makeDefaults()
        SpokenLanguages.save(["zh"], defaults: defaults)
        SpokenLanguages.save([], defaults: defaults)
        XCTAssertEqual(SpokenLanguages.current(defaults: defaults), ["zh"])
    }

    // MARK: - Hint for the engine

    func test_hint_roundTripsToExpectedScripts() {
        let hint = SpokenLanguages.hint(for: ["zh", "en", "ja", "ru"])
        XCTAssertEqual(hint, "zh,en,ja,ru")
        XCTAssertEqual(SpokenLanguages.expectedScripts(forHint: hint), [.latin, .han, .kana, .cyrillic])
    }

    func test_expectedScripts_latinIsAlwaysExpected() {
        XCTAssertEqual(SpokenLanguages.expectedScripts(forHint: "ar"), [.latin, .arabic])
        XCTAssertEqual(SpokenLanguages.expectedScripts(forHint: "fr,de"), [.latin])
    }

    func test_expectedScripts_emptyOrUnknownHintExpectsChineseAndEnglish() {
        XCTAssertEqual(SpokenLanguages.expectedScripts(forHint: ""), [.latin, .han])
        XCTAssertEqual(SpokenLanguages.expectedScripts(forHint: "auto"), [.latin, .han])
    }

    // MARK: - Scripts

    func test_scriptCounts_ignoreDigitsAndPunctuation() {
        let counts = WritingScript.counts(in: "我用 Python 3.11，OK？")
        XCTAssertEqual(counts[.han], 2)
        XCTAssertEqual(counts[.latin], 8)
        XCTAssertEqual(counts.count, 2)
    }

    // MARK: - Settings row

    func test_toggling_addsAndRemovesLanguages() {
        XCTAssertEqual(SpokenLanguagesSetting.toggling("ja", on: true, in: ["zh", "en"]), ["zh", "en", "ja"])
        XCTAssertEqual(SpokenLanguagesSetting.toggling("en", on: false, in: ["zh", "en"]), ["zh"])
    }

    func test_toggling_keepsTheLastLanguage() {
        XCTAssertEqual(SpokenLanguagesSetting.toggling("zh", on: false, in: ["zh"]), ["zh"])
    }

    func test_summary_showsTwoNamesThenACount() {
        XCTAssertEqual(SpokenLanguagesSetting.summary(of: ["zh", "en"]), "中文, English")
        XCTAssertEqual(SpokenLanguagesSetting.summary(of: ["zh", "en", "ja", "ko"]), "中文, English +2")
        XCTAssertEqual(SpokenLanguagesSetting.spokenSummary(of: ["zh", "en", "ja"]), "中文, English, 日本語")
    }
}
