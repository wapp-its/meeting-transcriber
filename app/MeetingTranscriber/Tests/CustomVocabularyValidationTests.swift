import Foundation
@testable import MeetingTranscriber
import XCTest

/// The validation shared by the local vocabulary file and downloaded copies.
/// The local-file results are pinned through `AppSettings` in
/// `CustomVocabularyTests`; these cases judge downloaded bytes.
final class CustomVocabularyValidationTests: XCTestCase {
    func testDownloadedBytesAreJudgedWithTheLocalFileLimits() {
        let cases: [(String, Data, CustomVocabularyValidation)] = [
            ("empty", Data(), .empty),
            ("whitespace only", Data("\n  \n\t\n".utf8), .empty),
            ("257 terms", Data((0 ... 256).map { "Term\($0)" }.joined(separator: "\n").utf8), .tooManyTerms),
            ("513-byte term", Data(String(repeating: "x", count: 513).utf8), .termTooLong),
            (
                "256 KB + 1 byte",
                Data(repeating: UInt8(ascii: "a"), count: WhisperVocabularyPrompt.maximumFileBytes + 1),
                .tooLarge,
            ),
            ("not UTF-8", Data([0x4E, 0xFF, 0xFE, 0x0A]), .unavailable),
            ("duplicates counted once", Data("Northstar\nnorthstar\nAster\n".utf8), .ready(termCount: 2)),
        ]

        for (label, data, expected) in cases {
            XCTAssertEqual(CustomVocabularyValidation.validate(data: data), expected, label)
        }
    }

    func testOversizedContentIsNotRead() {
        let validation = CustomVocabularyValidation.validate(
            byteCount: UInt64(WhisperVocabularyPrompt.maximumFileBytes + 1),
        ) {
            XCTFail("contents read despite the size limit")
            return nil
        }

        XCTAssertEqual(validation, .tooLarge)
    }
}
