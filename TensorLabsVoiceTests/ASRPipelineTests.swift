import XCTest
@testable import TensorLabsVoice

final class ASRPipelineTests: XCTestCase {
    func testPostProcessorNormalizesWhitespaceAndPunctuation() {
        let processor = PostProcessor()
        let output = processor.normalize("   hello    world   ")
        XCTAssertEqual(output, "Hello world.")
    }

    func testPostProcessorKeepsExistingQuestionMark() {
        let processor = PostProcessor()
        let output = processor.normalize("what time is it?")
        XCTAssertEqual(output, "What time is it?")
    }

    func testPostProcessorMapsSpokenPunctuation() {
        let processor = PostProcessor()
        let output = processor.normalize("hello comma world question mark")
        XCTAssertEqual(output, "Hello, world?")
    }

    func testPostProcessorSupportsParagraphCommands() {
        let processor = PostProcessor()
        let output = processor.normalize("first line new paragraph second line")
        XCTAssertEqual(output, "First line.\n\nSecond line.")
    }

    func testPostProcessorCollapsesDuplicateCommas() {
        let processor = PostProcessor()
        let output = processor.normalize("hello, comma world")
        XCTAssertEqual(output, "Hello, world.")
    }
}
