import XCTest
@testable import Murmur

/// Exercises `KeychainStore` and the `LLMAPIKeyStore` migration against a
/// throwaway Keychain service and a throwaway `UserDefaults` suite, so the
/// app's real key and preferences are never read or written.
final class KeychainStoreTests: XCTestCase {

    private let account = "test-account"
    private var keychain: KeychainStore!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        keychain = KeychainStore(service: "com.murmur.tests.\(UUID().uuidString)")
        suiteName = "com.murmur.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)

        // A machine with no usable Keychain (locked, or none in this session)
        // cannot run these.
        let usable = keychain.write("probe", account: "probe")
        keychain.delete(account: "probe")
        try XCTSkipUnless(usable, "No writable Keychain in this environment")
    }

    override func tearDown() {
        keychain.delete(account: account)
        keychain.delete(account: LLMAPIKeyStore.legacyDefaultsKey)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - KeychainStore

    func test_read_returnsNil_whenNothingStored() {
        XCTAssertNil(keychain.read(account: account))
    }

    func test_write_thenRead_roundTrips() {
        XCTAssertTrue(keychain.write("sk-first", account: account))
        XCTAssertEqual(keychain.read(account: account), "sk-first")
    }

    func test_write_replacesExistingValue() {
        keychain.write("sk-first", account: account)
        XCTAssertTrue(keychain.write("sk-second", account: account))
        XCTAssertEqual(keychain.read(account: account), "sk-second")
    }

    func test_write_emptyString_deletesItem() {
        keychain.write("sk-first", account: account)
        XCTAssertTrue(keychain.write("", account: account))
        XCTAssertNil(keychain.read(account: account))
    }

    func test_delete_isTrue_whenNothingStored() {
        XCTAssertTrue(keychain.delete(account: account))
    }

    func test_services_areIsolated() {
        keychain.write("sk-first", account: account)
        let other = KeychainStore(service: keychain.service + ".other")
        XCTAssertNil(other.read(account: account))
    }

    // MARK: - LLMAPIKeyStore

    func test_current_isNil_whenNoKeyAnywhere() {
        XCTAssertNil(LLMAPIKeyStore.current(keychain: keychain, defaults: defaults))
    }

    func test_save_thenCurrent_roundTrips() {
        XCTAssertTrue(LLMAPIKeyStore.save("sk-saved", keychain: keychain))
        XCTAssertEqual(LLMAPIKeyStore.current(keychain: keychain, defaults: defaults), "sk-saved")
    }

    func test_save_emptyString_clearsKey() {
        LLMAPIKeyStore.save("sk-saved", keychain: keychain)
        LLMAPIKeyStore.save("", keychain: keychain)
        XCTAssertNil(LLMAPIKeyStore.current(keychain: keychain, defaults: defaults))
    }

    func test_current_migratesPlaintextKey_andRemovesIt() {
        defaults.set("sk-legacy", forKey: LLMAPIKeyStore.legacyDefaultsKey)

        XCTAssertEqual(LLMAPIKeyStore.current(keychain: keychain, defaults: defaults), "sk-legacy")
        XCTAssertNil(defaults.object(forKey: LLMAPIKeyStore.legacyDefaultsKey),
                     "The plaintext copy must be removed once the Keychain holds the key")
        XCTAssertEqual(keychain.read(account: LLMAPIKeyStore.legacyDefaultsKey), "sk-legacy")
    }

    func test_migration_doesNotOverwriteKeychainValue() {
        LLMAPIKeyStore.save("sk-newer", keychain: keychain)
        defaults.set("sk-stale", forKey: LLMAPIKeyStore.legacyDefaultsKey)

        XCTAssertEqual(LLMAPIKeyStore.current(keychain: keychain, defaults: defaults), "sk-newer")
        XCTAssertNil(defaults.object(forKey: LLMAPIKeyStore.legacyDefaultsKey))
    }

    func test_migration_removesEmptyPlaintextValue_withoutStoringIt() {
        defaults.set("", forKey: LLMAPIKeyStore.legacyDefaultsKey)

        XCTAssertNil(LLMAPIKeyStore.current(keychain: keychain, defaults: defaults))
        XCTAssertNil(defaults.object(forKey: LLMAPIKeyStore.legacyDefaultsKey))
    }
}
