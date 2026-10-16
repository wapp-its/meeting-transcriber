@testable import LocalLLMHelper
import XCTest

final class RunRequestTests: XCTestCase {
    private static func json(contextLimit: Int = 32768, outputLimit: Int = 16000, folder: String = "/models/m") -> String {
        """
        {"modelFolder":"\(folder)","systemPrompt":"s","userPrompt":"u",\
        "contextLimit":\(contextLimit),"outputLimit":\(outputLimit),"outputPath":"/run/protocol.md"}
        """
    }

    func testParseSortsInputIntoRequestOrTheReasonThereIsNone() {
        let valid = RunRequest(
            modelFolder: "/models/m", systemPrompt: "s", userPrompt: "u",
            contextLimit: 32768, outputLimit: 16000, outputPath: "/run/protocol.md",
        )
        let cases: [(String, RunRequest.Parsed)] = [
            (Self.json(), .request(valid)),
            ("", .empty),
            ("not json", .malformed),
            (#"{"modelFolder":"/models/m"}"#, .malformed),
            (Self.json(contextLimit: 0), .invalid),
            (Self.json(outputLimit: -1), .invalid),
            (Self.json(folder: "models/m"), .invalid),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(RunRequest.parse(Data(input.utf8)), expected, input)
        }
    }
}
