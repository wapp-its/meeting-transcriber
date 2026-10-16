@testable import LocalLLMHelper
import MLXLMCommon
import XCTest

final class TokenWriterTests: XCTestCase {
    /// Decodes token n to "wn ", so the expected text follows from the ids.
    private struct WordTokenizer: MLXLMCommon.Tokenizer {
        let bosToken: String? = nil
        let eosToken: String? = nil
        let unknownToken: String? = nil

        func encode(text _: String, addSpecialTokens _: Bool) -> [Int] {
            []
        }

        func decode(tokenIds: [Int], skipSpecialTokens _: Bool) -> String {
            tokenIds.map { "w\($0) " }.joined()
        }

        func convertTokenToId(_: String) -> Int? {
            nil
        }

        func convertIdToToken(_: Int) -> String? {
            nil
        }

        // The optional collections are the shape of mlx-swift-lm's protocol.
        // swiftlint:disable discouraged_optional_collection
        func applyChatTemplate(
            messages _: [[String: any Sendable]],
            tools _: [[String: any Sendable]]?,
            additionalContext _: [String: any Sendable]?,
        ) -> [Int] {
            []
        }
        // swiftlint:enable discouraged_optional_collection
    }

    private static func stream(tokens: Range<Int>, stop: GenerateStopReason?) -> AsyncStream<TokenGeneration> {
        let (stream, continuation) = AsyncStream<TokenGeneration>.makeStream()
        for token in tokens {
            continuation.yield(.token(token))
        }
        if let stop {
            continuation.yield(.info(GenerateCompletionInfo(
                promptTokenCount: 1, generationTokenCount: tokens.count, promptTime: 0, generationTime: 0, stopReason: stop,
            )))
        }
        continuation.finish()
        return stream
    }

    func testWritesEveryTokenAndReportsProgressAtEachStepAndAtTheEnd() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("token-writer-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: path) }
        let output = try OutputFile(path: path.path)
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: WordTokenizer())
        var reported: [Int] = []

        let result = try await TokenWriter.consume(
            Self.stream(tokens: 0 ..< 70, stop: .length), detokenizer: &detokenizer, output: output,
        ) { reported.append($0) }

        XCTAssertEqual(result, .init(stop: .length, tokens: 70))
        XCTAssertEqual(reported, [32, 64, 70])
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), (0 ..< 70).map { "w\($0) " }.joined())
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testStreamWithoutAFinalEventHasNoStopReason() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("token-writer-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: path) }
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: WordTokenizer())

        let result = try await TokenWriter.consume(
            Self.stream(tokens: 0 ..< 3, stop: nil), detokenizer: &detokenizer, output: OutputFile(path: path.path),
        ) { _ in }

        XCTAssertEqual(result, .init(stop: nil, tokens: 3))
    }

    func testOutputFileRefusesASymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("token-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("protocol.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("elsewhere.md"))

        XCTAssertThrowsError(try OutputFile(path: link.path))
    }
}
