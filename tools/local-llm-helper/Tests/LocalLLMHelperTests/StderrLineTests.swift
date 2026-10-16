@testable import LocalLLMHelper
import XCTest

final class StderrLineTests: XCTestCase {
    func testLinesHaveTheDocumentedFormat() {
        let cases: [(StderrLine, String)] = [
            (.started, "lifecycle event=started"),
            (.prompt(tokens: 1200, contextLimit: 32768, outputLimit: 16000), "lifecycle event=prompt tokens=1200 context=32768 output=16000"),
            (.loading, "progress phase=loading"),
            (.prefill(chunk: 3, total: 41), "progress phase=prefill chunk=3 total=41"),
            (.writing(tokens: 64), "progress phase=writing tokens=64"),
            (.exited(.written, nil), "lifecycle event=exit status=0 reason=written"),
            (.exited(.incomplete, nil), "lifecycle event=exit status=10 reason=incomplete"),
            (.exited(.modelUnusable, .problems(2)), "lifecycle event=exit status=11 reason=model-unusable problems=2"),
            (.exited(.promptTooLong, nil), "lifecycle event=exit status=12 reason=prompt-too-long"),
            (.exited(.terminated, .cause(.sigterm)), "lifecycle event=exit status=13 reason=terminated cause=sigterm"),
            (.exited(.terminated, .cause(.parentGone)), "lifecycle event=exit status=13 reason=terminated cause=parent-gone"),
            (.exited(.failure, .failed(.badRequest)), "lifecycle event=exit status=1 reason=failure error=bad-request"),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(line.text, expected)
        }
    }

    /// The numbers the app mirrors must be the ones README.md documents.
    func testReadmeDocumentsEveryExitStatus() throws {
        let readme = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("README.md"),
            encoding: .utf8,
        )
        let expected: [ExitStatus: Int32] = [
            .written: 0, .failure: 1, .incomplete: 10, .modelUnusable: 11, .promptTooLong: 12, .terminated: 13,
        ]
        for status in ExitStatus.allCases {
            XCTAssertEqual(status.rawValue, expected[status], "\(status)")
            XCTAssertTrue(readme.contains("| \(status.rawValue) | `\(status.reason)` |"), "README row for \(status)")
        }
    }

    func testPrefillChunksCountUpToTheTotal() {
        // 1000 positions at step 512: two equal chunks for the first 999, then
        // the final forward with the last position.
        let long = PrefillProgress(totalPositions: 1000)
        XCTAssertEqual(long.totalChunks, 3)
        XCTAssertEqual([500, 999, 1000].map(long.chunk(processed:)), [1, 2, 3])

        let short = PrefillProgress(totalPositions: 100)
        XCTAssertEqual(short.totalChunks, 2)
        XCTAssertEqual([99, 100].map(short.chunk(processed:)), [1, 2])

        // More callbacks than predicted never pass the total before the end.
        XCTAssertEqual(long.chunk(processed: 998), 2)
    }
}
