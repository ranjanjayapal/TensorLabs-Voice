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
}
