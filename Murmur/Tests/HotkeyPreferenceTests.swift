import AppKit
import XCTest
@testable import Murmur

/// `HotkeyPreference` against a throwaway `UserDefaults` suite. `load` must
/// return what was saved, because the app registers at launch from the same
/// two keys Settings writes.
final class HotkeyPreferenceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.murmur.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_load_isRightCommand_whenNothingSaved() {
        XCTAssertEqual(HotkeyPreference.load(from: defaults), .rightCommand)
    }

    func test_saveKeyCombo_thenLoad_returnsSameCombo() {
        let combo = HotkeyTrigger.keyCombo(key: .d, modifiers: [.option, .shift])
        HotkeyPreference.save(combo, to: defaults)
        XCTAssertEqual(HotkeyPreference.load(from: defaults), combo)
    }

    func test_saveDefaultCustomShortcut_survivesReload() {
        // Turning "Right Command" off without recording a shortcut.
        let combo = HotkeyTrigger.keyCombo(
            key: HotkeyPreference.defaultCustomKey,
            modifiers: HotkeyPreference.defaultCustomModifiers
        )
        HotkeyPreference.save(combo, to: defaults)
        XCTAssertEqual(HotkeyPreference.load(from: defaults), combo)
    }

    func test_saveRightCommand_clearsSavedCombo() {
        HotkeyPreference.save(.keyCombo(key: .d, modifiers: .option), to: defaults)
        HotkeyPreference.save(.rightCommand, to: defaults)

        XCTAssertEqual(HotkeyPreference.load(from: defaults), .rightCommand)
        XCTAssertNil(defaults.object(forKey: HotkeyPreference.keyCodeKey))
        XCTAssertNil(defaults.object(forKey: HotkeyPreference.modifiersKey))
    }

    func test_load_isRightCommand_whenOnlyOneKeyIsPresent() {
        defaults.set(49, forKey: HotkeyPreference.keyCodeKey)
        XCTAssertEqual(HotkeyPreference.load(from: defaults), .rightCommand)
    }

    func test_defaultCustomShortcut_isNotASystemSpaceShortcut() {
        XCTAssertEqual(HotkeyPreference.defaultCustomKey, .space)
        // Spotlight, input-source switching (two), Finder search, character viewer.
        let systemSpaceShortcuts: [NSEvent.ModifierFlags] = [
            .command, .control, [.control, .option], [.command, .option], [.control, .command],
        ]
        XCTAssertFalse(systemSpaceShortcuts.contains(HotkeyPreference.defaultCustomModifiers))
        XCTAssertFalse(HotkeyPreference.defaultCustomModifiers.isEmpty)
    }
}
