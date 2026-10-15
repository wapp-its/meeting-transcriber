@testable import LocalLLMHelper
import XCTest

final class ModelFolderCheckTests: XCTestCase {
    func testUsableFolderReportsNameQuantisationAndSize() async throws {
        let folder = try ModelFolderFixture()
        defer { folder.cleanUp() }
        let (report, tokenizer) = await ModelFolderCheck.inspect(folder.url)

        XCTAssertEqual(report.problems, [])
        XCTAssertTrue(report.usable)
        XCTAssertNotNil(tokenizer)
        XCTAssertEqual(report.name, "Fixture-4bit")
        XCTAssertEqual(report.modelType, "qwen3")
        XCTAssertEqual(report.quantization, .init(bits: 4, groupSize: 64))
        XCTAssertEqual(report.sizeBytes, Int64(2 * ModelFolderFixture.shardBytes.count))
        XCTAssertEqual(
            report.jsonLine(),
            #"{"modelType":"qwen3","name":"Fixture-4bit","problems":[],"quantization":{"bits":4,"groupSize":64},"#
                + #""sizeBytes":\#(2 * ModelFolderFixture.shardBytes.count),"usable":true}"#,
        )
    }

    func testEachMissingOrBrokenFileIsNamed() async throws {
        typealias Problem = ModelFolderReport.Problem
        let cases: [(String, (ModelFolderFixture) throws -> Void, [Problem])] = [
            ("no config", { try $0.remove("config.json") }, [Problem(file: "config.json", problem: .missing)]),
            ("config not JSON", { try $0.write("config.json", "{") }, [Problem(file: "config.json", problem: .invalid)]),
            ("config unreadable", { try $0.setPermissions("config.json", 0o000) }, [Problem(file: "config.json", problem: .unreadable)]),
            (
                "unsupported type",
                { try $0.writeJSON("config.json", ["model_type": "no-such-architecture"]) },
                [Problem(file: "config.json", problem: .unsupported)],
            ),
            ("no tokenizer", { try $0.remove("tokenizer.json") }, [Problem(file: "tokenizer.json", problem: .missing)]),
            ("tokenizer not JSON", { try $0.write("tokenizer.json", "{") }, [Problem(file: "tokenizer.json", problem: .invalid)]),
            ("no chat template", { try $0.remove("chat_template.jinja") }, [Problem(file: "chat_template.jinja", problem: .missing)]),
            (
                "template does not parse",
                { try $0.write("chat_template.jinja", "{% for %}") },
                [Problem(file: "chat_template.jinja", problem: .invalid)],
            ),
            (
                "shard missing",
                { try $0.remove(ModelFolderFixture.shards[1]) },
                [Problem(file: ModelFolderFixture.shards[1], problem: .missing)],
            ),
            (
                "no weights at all",
                { folder in
                    try folder.remove("model.safetensors.index.json")
                    try ModelFolderFixture.shards.forEach(folder.remove)
                },
                [Problem(file: "model.safetensors", problem: .missing)],
            ),
            (
                "two problems at once",
                { folder in
                    try folder.remove("tokenizer.json")
                    try folder.remove(ModelFolderFixture.shards[0])
                },
                [Problem(file: "tokenizer.json", problem: .missing), Problem(file: ModelFolderFixture.shards[0], problem: .missing)],
            ),
        ]
        for (name, breakFolder, expected) in cases {
            let folder = try ModelFolderFixture()
            defer { folder.cleanUp() }
            try breakFolder(folder)
            let (report, tokenizer) = await ModelFolderCheck.inspect(folder.url)
            XCTAssertEqual(report.problems, expected, name)
            XCTAssertFalse(report.usable, name)
            XCTAssertNil(tokenizer, name)
        }
    }

    func testMissingFolderIsReportedAsTheFolder() async {
        let (report, _) = await ModelFolderCheck.inspect(URL(fileURLWithPath: "/nonexistent/Some-Model"))
        XCTAssertEqual(report.problems, [.init(file: ".", problem: .missing)])
        XCTAssertEqual(report.name, "Some-Model")
    }

    func testPromptEndsWithTheEmptyThinkingBlock() async throws {
        let folder = try ModelFolderFixture()
        defer { folder.cleanUp() }
        let (_, loaded) = await ModelFolderCheck.inspect(folder.url)
        let tokenizer = try XCTUnwrap(loaded)
        let tokens = try Prompt.render(tokenizer: tokenizer, system: "system text", user: "user text")
        let rendered = tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
        XCTAssertTrue(rendered.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"), rendered)
    }

    func testPromptFitsOnlyWithRoomForTheWholeOutput() {
        XCTAssertTrue(Prompt.fits(promptTokens: 16768, outputLimit: 16000, contextLimit: 32768))
        XCTAssertFalse(Prompt.fits(promptTokens: 16769, outputLimit: 16000, contextLimit: 32768))
    }
}
