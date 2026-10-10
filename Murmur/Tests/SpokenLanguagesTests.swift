import XCTest
@testable import Murmur

final class SpokenLanguagesTests: XCTestCase {

    // MARK: - The language list

    func test_codesAreUnique() {
        let codes = SpokenLanguages.all.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    func test_listsTheThirtyLanguagesTheModelSupports() {
        XCTAssertEqual(SpokenLanguages.all.count, 30)
    }

    func test_normalised_dropsUnknownAndDuplicateCodes_andUsesListOrder() {
        XCTAssertEqual(SpokenLanguages.normalised(["ja", "xx", "en", "zh", "en"]), ["zh", "en", "ja"])
    }

    // MARK: - Stored setting

    private func makeDefaults() -> UserDefaults {
        let name = "SpokenLanguagesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func test_current_isEveryLanguageUntilTheUserNarrowsIt() {
        let defaults = makeDefaults()
        XCTAssertEqual(SpokenLanguages.current(defaults: defaults), SpokenLanguages.all.map(\.code))
        XCTAssertNil(defaults.stringArray(forKey: SpokenLanguages.defaultsKey),
                     "the default is not written back, so a language added later is included")
    }

    func test_current_ignoresTheOldLanguagePickerValue() {
        let defaults = makeDefaults()
        defaults.set("zh", forKey: "transcriptionLanguage")
        XCTAssertEqual(SpokenLanguages.current(defaults: defaults).count, SpokenLanguages.all.count)
    }

    func test_current_returnsWhatWasSaved() {
        let defaults = makeDefaults()
        SpokenLanguages.save(["en", "ko"], defaults: defaults)
        XCTAssertEqual(SpokenLanguages.current(defaults: defaults), ["en", "ko"])
    }

    func test_save_ignoresAnEmptySelection() {
        let defaults = makeDefaults()
        SpokenLanguages.save(["zh"], defaults: defaults)
        SpokenLanguages.save([], defaults: defaults)
        XCTAssertEqual(SpokenLanguages.current(defaults: defaults), ["zh"])
    }

    func test_save_selectingEverythingReturnsToTheDefault() {
        let defaults = makeDefaults()
        SpokenLanguages.save(["zh", "en"], defaults: defaults)
        SpokenLanguages.save(SpokenLanguages.all.map(\.code), defaults: defaults)
        XCTAssertNil(defaults.stringArray(forKey: SpokenLanguages.defaultsKey))
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

    func test_expectedScripts_hintWithNoKnownLanguageRestrictsNothing() {
        XCTAssertEqual(SpokenLanguages.expectedScripts(forHint: ""), Set(WritingScript.allCases))
        XCTAssertEqual(SpokenLanguages.expectedScripts(forHint: "auto"), Set(WritingScript.allCases))
    }

    func test_expectedScripts_everyLanguageExpectsEveryNamedScript() {
        let hint = SpokenLanguages.hint(for: SpokenLanguages.all.map(\.code))
        XCTAssertEqual(SpokenLanguages.expectedScripts(forHint: hint),
                       Set(WritingScript.allCases).subtracting([.other]))
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

    func test_summary_saysAllLanguagesWhenNothingIsTurnedOff() {
        let everything = SpokenLanguages.all.map(\.code)
        XCTAssertEqual(SpokenLanguagesSetting.summary(of: everything), "All languages")
        XCTAssertEqual(SpokenLanguagesSetting.spokenSummary(of: everything), "All languages")
    }
}
