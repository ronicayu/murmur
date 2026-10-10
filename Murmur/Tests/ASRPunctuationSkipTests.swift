import XCTest
@testable import Murmur

/// The punctuation model must only see bare transcripts: it adds a second mark
/// next to every one that is already there.
final class ASRPunctuationSkipTests: XCTestCase {

    func test_bareTranscript_isNotPunctuated() {
        XCTAssertFalse(ASRPunctuationService.isAlreadyPunctuated("那我再来看看现在怎么样了是不是可以用了呀"))
        XCTAssertFalse(ASRPunctuationService.isAlreadyPunctuated("所有只要处理 data 不管你是做 machine learning"))
    }

    func test_chinesePunctuation_isDetected() {
        XCTAssertTrue(ASRPunctuationService.isAlreadyPunctuated("你好呀，现在可以了吗？"))
        XCTAssertTrue(ASRPunctuationService.isAlreadyPunctuated("好像好了很多。"))
    }

    func test_asciiSentencePunctuation_isDetected() {
        XCTAssertTrue(ASRPunctuationService.isAlreadyPunctuated("我们用 Python, 然后部署"))
        XCTAssertTrue(ASRPunctuationService.isAlreadyPunctuated("这个可以吗?"))
        XCTAssertTrue(ASRPunctuationService.isAlreadyPunctuated("这样就好了."))
    }

    func test_dotsInsideTokens_areNotSentencePunctuation() {
        XCTAssertFalse(ASRPunctuationService.isAlreadyPunctuated("我用 Python 3.11 和 example.com"))
    }
}
