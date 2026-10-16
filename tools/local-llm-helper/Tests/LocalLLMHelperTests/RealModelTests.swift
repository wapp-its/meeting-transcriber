import Foundation
@testable import LocalLLMHelper
import XCTest

/// Runs against a real model folder, named by the environment variable
/// below, and skips without one. None of these load weights: the tokenizer
/// files alone stay far below 1 GB, while the weights of the tested model
/// take about 16 GB. The refusal test kills the helper the moment it starts
/// loading weights, so a broken refusal cannot load a model without the
/// app's memory guard.
final class RealModelTests: XCTestCase {
    private static let environmentKey = "LOCAL_LLM_HELPER_TEST_MODEL"
    private static let marker = "PROMPT-MARKER-0d27b4"

    private func modelFolder() throws -> URL {
        let path = ProcessInfo.processInfo.environment[Self.environmentKey] ?? ""
        try XCTSkipIf(path.isEmpty, "set \(Self.environmentKey) to a model folder to run this test")
        return URL(fileURLWithPath: path)
    }

    func testRenderedPromptEndsWithTheEmptyThinkingBlock() async throws {
        let folder = try modelFolder()
        let (report, loaded) = await ModelFolderCheck.inspect(folder)
        let tokenizer = try XCTUnwrap(loaded, "folder not usable: \(report.problems)")

        let tokens = try Prompt.render(tokenizer: tokenizer, system: "Write the minutes.", user: "[00:01] Speaker 1: Hello.")
        let rendered = tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)

        XCTAssertTrue(rendered.hasSuffix("<think>\n\n</think>\n\n"), String(rendered.suffix(80)).debugDescription)
    }

    func testTooLongPromptIsRefusedBeforeWeightsLoad() throws {
        let folder = try modelFolder()
        let runDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("local-llm-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDirectory) }
        let transcript = (1 ... 400).map { "[\($0 / 60):\($0 % 60)] Speaker \($0 % 3): \(Self.marker) we review item \($0)." }
        let request: [String: Any] = [
            "modelFolder": folder.path, "systemPrompt": "Write the minutes.", "userPrompt": transcript.joined(separator: "\n"),
            "contextLimit": 2048, "outputLimit": 1024, "outputPath": runDirectory.appendingPathComponent("protocol.md").path,
        ]

        let helper = try SpawnedHelper(HelperBinary.built.path, ["run"])
        try helper.send(JSONSerialization.data(withJSONObject: request))
        helper.closeStdin()
        let ending = helper.waitForEnding(timeout: 60) { helper.stderr.text.contains(StderrLine.loading.text) }

        XCTAssertFalse(helper.stderr.text.contains(StderrLine.loading.text), "started loading weights")
        let ended = try XCTUnwrap(ending)
        XCTAssertEqual(ended.status, ExitStatus.promptTooLong.rawValue, helper.stderr.text)
        XCTAssertLessThan(ended.peakResidentBytes, 1 << 30)
        XCTAssertTrue(helper.stderr.waitForEnd())
        XCTAssertFalse(helper.stderr.text.contains(Self.marker))
    }

    func testCheckReportsNameQuantisationAndSize() throws {
        let folder = try modelFolder()
        let helper = try SpawnedHelper(HelperBinary.built.path, ["check", folder.path])

        XCTAssertEqual(helper.waitForEnding(timeout: 60)?.status, 0)
        XCTAssertTrue(helper.stdout.waitForEnd())
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(helper.stdout.text.utf8)) as? [String: Any])
        XCTAssertEqual(report["name"] as? String, folder.lastPathComponent)
        let quantization = try XCTUnwrap(report["quantization"] as? [String: Int], "the tested model is quantised")
        XCTAssertGreaterThan(quantization["bits"] ?? 0, 0)
        XCTAssertGreaterThan(report["sizeBytes"] as? Int ?? 0, 0)
    }
}
