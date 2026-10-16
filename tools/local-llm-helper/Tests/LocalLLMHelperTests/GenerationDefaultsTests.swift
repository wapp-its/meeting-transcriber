@testable import LocalLLMHelper
import XCTest

final class GenerationDefaultsTests: XCTestCase {
    /// Pins the sampling the pilot's protocols are judged with (Qwen3's
    /// thinking-off recommendation) and the per-request limits. Changing the
    /// sampling, for example to read the model's generation_config.json, has to
    /// change this test on purpose.
    func testParametersCarryTheFixedSamplingAndTheRequestLimits() {
        let parameters = GenerationDefaults.parameters(contextLimit: 32768, outputLimit: 16000, prefillProgress: nil)

        XCTAssertEqual(parameters.temperature, 0.7)
        XCTAssertEqual(parameters.topP, 0.8)
        XCTAssertEqual(parameters.topK, 20)
        XCTAssertEqual(parameters.maxKVSize, 32768)
        XCTAssertEqual(parameters.maxTokens, 16000)
        XCTAssertEqual(parameters.prefill.stepSize, 512)
        XCTAssertNil(parameters.kvBits)
    }
}
