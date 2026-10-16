import Darwin
import Foundation
@testable import LocalLLMHelper
import XCTest

/// The helper as the app meets it: a process, its exit status and its stderr.
/// None of these load weights.
final class ProcessContractTests: XCTestCase {
    /// Put into every prompt; no line the helper writes may contain it.
    private static let marker = "PROMPT-MARKER-5f1c9e"

    private static func request(folder: String, outputPath: String, contextLimit: Int, userPrompt: String) -> Data {
        let object: [String: Any] = [
            "modelFolder": folder, "systemPrompt": "Write minutes. \(marker)", "userPrompt": userPrompt,
            "contextLimit": contextLimit, "outputLimit": 64, "outputPath": outputPath,
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func exitLine(_ status: ExitStatus, _ detail: StderrLine.Detail? = nil) -> String {
        StderrLine.exited(status, detail).text
    }

    private struct Refusal {
        let name: String
        let input: Data
        let status: ExitStatus
        var detail: StderrLine.Detail?
        /// Whether the run gets as far as loading the weights.
        var loads = false
    }

    func testEachRefusalEndsWithItsStatusAndNoPromptText() throws {
        let fixture = try ModelFolderFixture()
        defer { fixture.cleanUp() }
        let output = fixture.url.deletingLastPathComponent().appendingPathComponent("protocol.md").path
        let transcript = "[00:01] Speaker 1: \(Self.marker) " + String(repeating: "We agree on the budget. ", count: 40)
        let cases = [
            Refusal(name: "stdin closed without a request", input: Data(), status: .terminated, detail: .cause(.stdinClosed)),
            Refusal(
                name: "not a request", input: Data("{\"userPrompt\":\"\(Self.marker)\"}".utf8),
                status: .failure, detail: .failed(.badRequest),
            ),
            Refusal(
                name: "missing model folder",
                input: Self.request(folder: "/nonexistent/model", outputPath: output, contextLimit: 32768, userPrompt: transcript),
                status: .modelUnusable, detail: .problems(1),
            ),
            Refusal(
                name: "prompt too long",
                input: Self.request(folder: fixture.url.path, outputPath: output, contextLimit: 512, userPrompt: transcript),
                status: .promptTooLong,
            ),
            Refusal(
                name: "model fails to load",
                input: Self.request(folder: fixture.url.path, outputPath: output, contextLimit: 32768, userPrompt: transcript),
                status: .failure, detail: .failed(.load), loads: true,
            ),
        ]
        for refusal in cases {
            let helper = try SpawnedHelper(HelperBinary.built.path, ["run"])
            helper.send(refusal.input)
            helper.closeStdin()
            let ending = helper.waitForEnding()
            XCTAssertTrue(helper.stderr.waitForEnd(), refusal.name)
            let stderr = helper.stderr.text
            XCTAssertEqual(ending?.status, refusal.status.rawValue, refusal.name)
            XCTAssertTrue(stderr.hasSuffix(Self.exitLine(refusal.status, refusal.detail) + "\n"), "\(refusal.name): \(stderr)")
            XCTAssertEqual(stderr.contains(StderrLine.loading.text), refusal.loads, refusal.name)
            XCTAssertFalse(stderr.contains(Self.marker), refusal.name)
            XCTAssertFalse(helper.stdout.text.contains(Self.marker), refusal.name)
        }
    }

    func testSIGTERMEndsTheRunWithTheTerminatedStatus() throws {
        let helper = try SpawnedHelper(HelperBinary.built.path, ["run"])
        XCTAssertTrue(helper.stderr.waitFor(StderrLine.started.text))

        kill(helper.pid, SIGTERM)

        let ending = try XCTUnwrap(helper.waitForEnding(timeout: 10))
        XCTAssertEqual(ending.status, ExitStatus.terminated.rawValue)
        XCTAssertTrue(helper.stderr.waitFor(Self.exitLine(.terminated, .cause(.sigterm))))
    }

    /// The helper's parent is a shell that is then killed. The test holds the
    /// helper's standard input open, so only the parent watch can end it. A
    /// process that is not this test's child cannot be reaped here, so its
    /// exit status is read from the exit line it writes before `_exit`.
    func testParentDeathEndsTheRunWithTheTerminatedStatus() throws {
        let script = #"exec 3<&0; "$0" run <&3 3<&- & echo "$!"; wait"#
        let shell = try SpawnedHelper("/bin/sh", ["-c", script, HelperBinary.built.path])
        XCTAssertTrue(shell.stdout.waitFor("\n"))
        let helperPID = try XCTUnwrap(pid_t(shell.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(shell.stderr.waitFor(StderrLine.started.text))

        kill(shell.pid, SIGKILL)
        XCTAssertNotNil(shell.waitForEnding(timeout: 10))

        XCTAssertTrue(shell.stderr.waitForEnd(timeout: 10), "the helper kept running without its parent")
        XCTAssertTrue(shell.stderr.text.contains(Self.exitLine(.terminated, .cause(.parentGone))), shell.stderr.text)
        let deadline = Date().addingTimeInterval(10)
        while kill(helperPID, 0) == 0, Date() < deadline {
            usleep(20000)
        }
        XCTAssertNotEqual(kill(helperPID, 0), 0, "helper \(helperPID) still exists")
    }

    func testCheckPrintsOneJSONLineAndExitsWithTheVerdict() throws {
        let fixture = try ModelFolderFixture()
        defer { fixture.cleanUp() }

        let usable = try SpawnedHelper(HelperBinary.built.path, ["check", fixture.url.path])
        XCTAssertEqual(usable.waitForEnding()?.status, 0)
        XCTAssertTrue(usable.stdout.waitForEnd())
        let line = usable.stdout.text
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(report["usable"] as? Bool, true)
        XCTAssertEqual(report["name"] as? String, "Fixture-4bit")

        try fixture.remove("tokenizer.json")
        let broken = try SpawnedHelper(HelperBinary.built.path, ["check", fixture.url.path])
        XCTAssertEqual(broken.waitForEnding()?.status, ExitStatus.modelUnusable.rawValue)
        XCTAssertTrue(broken.stdout.waitFor(#"{"file":"tokenizer.json","problem":"missing"}"#))
    }

    /// A debug build of MLX fails this test's quantized matmul with a GPU
    /// timeout, so it runs against the release build only.
    func testReleaseBuildSelfTestPasses() throws {
        let binary = HelperBinary.release
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "no release build; run swift build -c release first")
        let helper = try SpawnedHelper(binary.path, ["selftest"])
        XCTAssertEqual(helper.waitForEnding(timeout: 60)?.status, 0)
        XCTAssertTrue(helper.stdout.waitFor("SELFTEST OK"), helper.stdout.text)
    }
}
