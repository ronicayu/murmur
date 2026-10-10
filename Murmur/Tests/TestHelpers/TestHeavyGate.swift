import XCTest

/// Skip-by-default gate for tests that load real ML models or otherwise
/// allocate hundreds of MB of RAM. Opt in by running with
/// `MURMUR_RUN_HEAVY_TESTS=1` in the environment.
///
/// The Mac mini used for development has limited RAM and tests in this
/// category have crashed it; opt-in is mandatory.
enum TestHeavyGate {
    static func requireOptIn() throws {
        let value = ProcessInfo.processInfo.environment["MURMUR_RUN_HEAVY_TESTS"]
        try XCTSkipUnless(
            value == "1",
            "Heavy test skipped. Set MURMUR_RUN_HEAVY_TESTS=1 to run."
        )
    }
}
