#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// What the Claude CLI provider gains from the shared process runner: a
    /// timeout that also stops a CLI that prints nothing, and a run that
    /// survives a CLI exiting without reading its input.
    final class ClaudeCLIProtocolGeneratorRunnerTests: XCTestCase {
        /// A CLI that reads its prompt and then hangs without printing must be
        /// stopped at the timeout. The guard keeps a regression from hanging
        /// the suite: it fails the test instead of waiting for the fake CLI.
        func testGenerateTimesOutACLIThatPrintsNothing() async throws {
            let script = try Self.makeFakeClaudeScript(body: "cat > /dev/null\nsleep 30")
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German", timeout: 1)
            let returned = expectation(description: "generate() returned")
            let run = Task {
                defer { returned.fulfill() }
                return try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)
            }

            let waited = await XCTWaiter.fulfillment(of: [returned], timeout: 5)
            guard waited == .completed else {
                XCTFail("generate() did not return within 5 s although the timeout is 1 s")
                return
            }
            do {
                _ = try await run.value
                XCTFail("Expected generate() to throw .timeout")
            } catch ProtocolError.timeout {}
        }

        /// A CLI that fails before reading a large prompt (a usage error, a
        /// wrong binary) closes its stdin while the app is still writing. That
        /// must end as the CLI's failure, not take the app down.
        func testGenerateSurvivesACLIThatExitsWithoutReadingItsPrompt() async throws {
            let script = try Self.makeFakeClaudeScript(body: "exit 1")
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German")
            let transcript = String(repeating: "x", count: 1 << 20)
            do {
                _ = try await generator.generate(transcript: transcript, title: "Sync", diarized: false)
                XCTFail("Expected generate() to throw .cliFailed")
            } catch let ProtocolError.cliFailed(code, _) {
                XCTAssertEqual(code, 1)
            }
        }

        func testGenerateReportsACLIThatCannotStartAsNotFound() async throws {
            let missing = NSTemporaryDirectory() + "no-such-claude-\(UUID().uuidString)"

            let generator = ClaudeCLIProtocolGenerator(claudeBin: missing, language: "German")
            do {
                _ = try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)
                XCTFail("Expected generate() to throw .cliNotFound")
            } catch let ProtocolError.cliNotFound(bin) {
                XCTAssertEqual(bin, missing)
            }
        }

        func testGenerateReportsACLIThatRepliesWithNothingAsEmptyProtocol() async throws {
            let script = try Self.makeFakeClaudeScript(body: "cat > /dev/null")
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German")
            do {
                _ = try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)
                XCTFail("Expected generate() to throw .emptyProtocol")
            } catch ProtocolError.emptyProtocol {}
        }

        /// The CLI's output is decoded once it has ended, so a last line
        /// without a newline still counts.
        func testGenerateKeepsALastLineWithoutANewline() async throws {
            let script = try Self.makeFakeClaudeScript(
                body: """
                cat > /dev/null
                printf '%s' '{"type":"content_block_delta","delta":{"type":"text_delta","text":"Protocol body"}}'
                """,
            )
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German")
            let result = try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)

            XCTAssertEqual(result, "Protocol body")
        }

        /// Stdout beyond the runner's cap stops the CLI; the error names the
        /// tool and nothing it printed.
        func testGenerateFailsOnOutputOverTheCap() async throws {
            let script = try Self.makeFakeClaudeScript(
                body: "cat > /dev/null\nhead -c \(CLIProcessRunner.defaultMaxStdoutBytes + 1) /dev/zero",
            )
            defer { try? FileManager.default.removeItem(atPath: script) }

            let generator = ClaudeCLIProtocolGenerator(claudeBin: script, language: "German")
            do {
                _ = try await generator.generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)
                XCTFail("Expected generate() to throw .commandOutputTooLarge")
            } catch let error as ProtocolError {
                guard case let .commandOutputTooLarge(tool) = error else {
                    XCTFail("Expected .commandOutputTooLarge, got \(error)")
                    return
                }
                XCTAssertEqual(tool, "Claude CLI")
                XCTAssertEqual(error.errorDescription, "Claude CLI wrote more output than the app accepts")
            }
        }

        /// A fake `claude` that answers the `--help` probe at once (so the
        /// probe never waits for `body`) and otherwise runs `body`.
        private static func makeFakeClaudeScript(body: String) throws -> String {
            let path = NSTemporaryDirectory() + "fake-claude-\(UUID().uuidString).sh"
            let script = "#!/bin/sh\nif [ \"$1\" = \"--help\" ]; then exit 0; fi\n\(body)\n"
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
    }
#endif
