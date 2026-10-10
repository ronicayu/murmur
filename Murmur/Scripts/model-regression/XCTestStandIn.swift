import Foundation

// A stand-in for the parts of XCTest that the model tests use. It exists so
// that those tests can run on a Mac that has the Command Line Tools but not
// Xcode, where `swift test` cannot build the package. See model-regression.sh.

final class Failures: @unchecked Sendable {
    static let shared = Failures()
    private let lock = NSLock()
    private var current: [String] = []

    func add(_ message: String, _ file: StaticString, _ line: UInt) {
        let name = "\(file)".split(separator: "/").last.map(String.init) ?? ""
        lock.withLock { current.append("\(name):\(line): \(message)") }
    }

    func take() -> [String] {
        lock.withLock { let all = current; current = []; return all }
    }
}

class XCTestCase: NSObject {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}

struct XCTSkip: Error {
    let message: String
}

struct XCTUnwrapFailed: Error {}

func XCTSkipUnless(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "") throws {
    if try !condition() { throw XCTSkip(message: message()) }
}

func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    Failures.shared.add("XCTFail: \(message)", file, line)
}

func XCTAssertTrue(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    if (try? condition()) != true { Failures.shared.add("XCTAssertTrue failed: \(message())", file, line) }
}

func XCTUnwrap<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let unwrapped = try value() else {
        Failures.shared.add("XCTUnwrap failed: value is nil", file, line)
        throw XCTUnwrapFailed()
    }
    return unwrapped
}

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    guard let x = try? a(), let y = try? b() else {
        Failures.shared.add("XCTAssertEqual failed: an expression threw", file, line)
        return
    }
    if x != y { Failures.shared.add("XCTAssertEqual failed: (\(x)) is not equal to (\(y)) \(message())", file, line) }
}

func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    guard let x = try? a(), let y = try? b() else {
        Failures.shared.add("XCTAssertEqual failed: an expression threw", file, line)
        return
    }
    if abs(x - y) > accuracy {
        Failures.shared.add("XCTAssertEqual failed: (\(x)) is not within \(accuracy) of (\(y)) \(message())", file, line)
    }
}

private func compare<T: Comparable>(_ name: String, _ a: () throws -> T, _ b: () throws -> T, _ message: () -> String,
                                    _ file: StaticString, _ line: UInt, _ holds: (T, T) -> Bool) {
    guard let x = try? a(), let y = try? b() else {
        Failures.shared.add("\(name) failed: an expression threw", file, line)
        return
    }
    if !holds(x, y) { Failures.shared.add("\(name) failed: (\(x)) against (\(y)) \(message())", file, line) }
}

func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
    compare("XCTAssertGreaterThan", a, b, message, file, line, >)
}

func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                _ message: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {
    compare("XCTAssertGreaterThanOrEqual", a, b, message, file, line, >=)
}

func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    compare("XCTAssertLessThan", a, b, message, file, line, <)
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    compare("XCTAssertLessThanOrEqual", a, b, message, file, line, <=)
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
    if (try? expression()) != nil { Failures.shared.add("XCTAssertThrowsError failed: nothing was thrown \(message())", file, line) }
}
