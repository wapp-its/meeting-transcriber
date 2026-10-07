#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The Codex CLI preset and the custom command, run against `#!/bin/sh`
    /// fake programs that report what they received or misbehave on purpose.
    /// Every generator reads the pinned prompt below, never the developer's
    /// own custom prompt.
    final class CommandProtocolGeneratorTests: XCTestCase {
        private static let transcript = "Speaker 1: the quarterly numbers"
        private static let pinnedPrompt = "PINNED PROMPT\n"
        private static let codexTemplate = [
            "codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check",
            "--sandbox", "read-only", "--output-last-message", "{output_file}", "-",
        ]

        /// Holds the fake programs, the pinned prompt and what fakes record.
        private var scratch = FileManager.default.temporaryDirectory

        override func setUpWithError() throws {
            try super.setUpWithError()
            scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("command-generator-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            try Self.pinnedPrompt.write(to: promptURL, atomically: true, encoding: .utf8)
        }

        override func tearDownWithError() throws {
            try? FileManager.default.removeItem(at: scratch)
            try super.tearDownWithError()
        }

        // MARK: - Input

        func testStdinModeSendsTheFullPromptAndReturnsStdout() async throws {
            let program = try makeProgram("""
            cat > '\(record("stdin"))'
            ls -A > '\(record("entries"))'
            echo 'The protocol'
            """)

            let result = try await custom([program.path]).generate(transcript: Self.transcript, title: "Sync", diarized: false)

            XCTAssertEqual(result, "The protocol")
            XCTAssertEqual(try recorded("stdin"), Self.pinnedPrompt + Self.transcript)
            XCTAssertEqual(try recorded("entries"), "", "a stdin-only command's run folder was not empty at start")
        }

        /// `{prompt_file}` holds exactly what stdin mode sends, `{transcript_file}`
        /// the transcript alone; nothing arrives on stdin, and the folder holds
        /// only those two owner-only files.
        func testFileInputsHoldThePromptAndTheTranscriptOwnerOnly() async throws {
            let program = try makeProgram("""
            transcript="${2#--transcript=}"
            cp "$1" '\(record("prompt"))'
            cp "$transcript" '\(record("transcript"))'
            cat > '\(record("stdin"))'
            stat -f %Lp "$1" "$transcript" . > '\(record("modes"))'
            ls -A > '\(record("entries"))'
            echo 'The protocol'
            """)

            let result = try await custom([program.path, "{prompt_file}", "--transcript={transcript_file}"])
                .generate(transcript: Self.transcript, title: "Sync", diarized: false)

            XCTAssertEqual(result, "The protocol")
            XCTAssertEqual(try recorded("prompt"), Self.pinnedPrompt + Self.transcript)
            XCTAssertEqual(try recorded("transcript"), Self.transcript)
            XCTAssertEqual(try recorded("stdin"), "", "the program got input on stdin although it reads files")
            XCTAssertEqual(try recorded("modes"), "600\n600\n700\n", "input files must be 0600, the run folder 0700")
            XCTAssertEqual(try recorded("entries"), "prompt.txt\ntranscript.txt\n")
        }

        // MARK: - Output

        func testOutputFileIsTheProtocolAndStdoutIsIgnored() async throws {
            let program = try makeProgram("""
            cat > /dev/null
            echo 'stdout text'
            printf 'File protocol\\n' > "$1"
            """)

            let result = try await custom([program.path, "{output_file}"])
                .generate(transcript: Self.transcript, title: "Sync", diarized: false)

            XCTAssertEqual(result, "File protocol")
        }

        /// A missing output file, a symlink or a FIFO at its path, and blank
        /// output are no protocol. The FIFO must not hang the run (a blocking
        /// open would never return), and the symlink's target is never read.
        func testEveryWayOfProducingNoProtocolFailsTheRun() async throws {
            let secret = scratch.appendingPathComponent("secret.txt")
            try "SECRET FILE TEXT".write(to: secret, atomically: true, encoding: .utf8)
            let cases: [(name: String, body: String, arguments: [String])] = [
                ("missing output file", "echo 'stdout text'", ["{output_file}"]),
                ("symlink at the output path", "ln -s '\(secret.path)' \"$1\"", ["{output_file}"]),
                ("FIFO at the output path", "mkfifo \"$1\"", ["{output_file}"]),
                ("blank output file", "printf ' \\n\\n' > \"$1\"", ["{output_file}"]),
                ("blank stdout", "printf ' \\n\\n'", []),
            ]
            for (name, body, arguments) in cases {
                let program = try makeProgram("cat > /dev/null\n\(body)")
                let error = await generateError(custom([program.path] + arguments), within: 5)

                guard case let .commandProducedNoProtocol(tool)? = error else {
                    XCTFail("\(name): expected .commandProducedNoProtocol, got \(String(describing: error))")
                    continue
                }
                XCTAssertEqual(tool, "Custom command", name)
                XCTAssertEqual(error?.errorDescription, "Custom command produced no protocol", name)
            }
        }

        func testOutputOverTheCapIsTooLarge() async throws {
            let cases: [(name: String, body: String, arguments: [String])] = [
                ("output file", "head -c 2048 /dev/zero > \"$1\"", ["{output_file}"]),
                ("stdout", "head -c 2048 /dev/zero", []),
            ]
            for (name, body, arguments) in cases {
                let program = try makeProgram("cat > /dev/null\n\(body)")
                var generator = custom([program.path] + arguments)
                generator.maxOutputBytes = 1024

                let error = await generateError(generator)

                guard case let .commandOutputTooLarge(tool)? = error else {
                    XCTFail("\(name): expected .commandOutputTooLarge, got \(String(describing: error))")
                    continue
                }
                XCTAssertEqual(tool, "Custom command", name)
            }
        }

        // MARK: - No shell

        func testArgumentsReachTheProgramUnchangedAndAreNeverExecuted() async throws {
            let quoted = "it's \"quoted\" `touch \(record("pwned3"))` | x"
            let model = "$(touch \(record("pwned2")))"
            let program = try makeProgram(#"for arg in "$@"; do printf '%s\n' "$arg"; done"#)

            let result = try await custom(
                [program.path, "{transcript_file};touch \(record("pwned"))", "{model}", quoted], model: model,
            ).generate(transcript: Self.transcript, title: "Sync", diarized: false)

            let lines = result.components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 3, "unexpected arguments: \(result)")
            XCTAssertTrue(lines[0].hasPrefix("/"), lines[0])
            XCTAssertTrue(lines[0].hasSuffix("/transcript.txt;touch \(record("pwned"))"), lines[0])
            XCTAssertEqual(lines.dropFirst().first, model)
            XCTAssertEqual(lines.last, quoted)
            for name in ["pwned", "pwned2", "pwned3"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: record(name)), "an argument was executed: \(name) exists")
            }
        }

        // MARK: - Configuration and program resolution

        func testConfigurationErrorsStopBeforeAnythingStarts() async throws {
            let program = try makeProgram("touch '\(record("started"))'\necho 'The protocol'")
            let cases: [(generator: CommandProtocolGenerator, message: String)] = [
                (custom(["", "  "]), "No custom command is set"),
                (custom([program.path, "{model}"], model: " "), "The custom command uses {model}, but no model is set"),
            ]
            for (generator, message) in cases {
                let error = await generateError(generator)

                guard case let .commandNotConfigured(text)? = error else {
                    XCTFail("expected .commandNotConfigured, got \(String(describing: error))")
                    continue
                }
                XCTAssertEqual(text, message)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: record("started")), "the program was started")
        }

        func testProgramThatCannotBeFoundFailsNamingTheToolAndTheProgram() async {
            let unknown = "no-such-program-\(UUID().uuidString)"
            let cases: [(generator: CommandProtocolGenerator, tool: String, program: String)] = [
                (custom([unknown, "run"]), "Custom command", unknown),
                (custom(["bin/tool"]), "Custom command", "tool"),
                (codex(program: scratch.appendingPathComponent("missing/codex").path), "Codex CLI", "codex"),
            ]
            for (generator, tool, program) in cases {
                let error = await generateError(generator)

                guard case let .commandNotFound(foundTool, foundProgram)? = error else {
                    XCTFail("\(program): expected .commandNotFound, got \(String(describing: error))")
                    continue
                }
                XCTAssertEqual(foundTool, tool)
                XCTAssertEqual(foundProgram, program)
            }
        }

        func testResolveProgram() throws {
            let bin = scratch.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
            let name = "fake-tool-\(UUID().uuidString)"
            let tool = bin.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            let plain = bin.appendingPathComponent("plain.txt")
            try "text".write(to: plain, atomically: true, encoding: .utf8)
            let environment = ["PATH": "/nonexistent:\(bin.path)"]

            let cases: [(program: String, environment: [String: String], expected: String?)] = [
                (tool.path, [:], tool.path),
                (plain.path, [:], nil),
                (bin.path, [:], nil),
                ("~/bin/\(name)", [:], tool.path),
                (name, environment, tool.path),
                ("no-such-program-\(UUID().uuidString)", environment, nil),
                ("bin/\(name)", ["PATH": scratch.path], nil),
            ]
            for (program, environment, expected) in cases {
                let resolved = CLIProcessRunner.resolveProgram(program, environment: environment, home: scratch.path)
                XCTAssertEqual(resolved?.path, expected, program)
            }
        }

        // MARK: - Failures

        /// A5: the program's stdout and stderr can hold meeting content, so
        /// they never become part of the error's text.
        func testNonZeroExitCarriesNoProgramOutput() async throws {
            let program = try makeProgram("cat >&2\necho 'stderr marker' >&2\necho 'stdout marker'\nexit 2")

            let error = await generateError(custom([program.path]))

            guard case let .commandFailed(tool, exitCode, reason)? = error else {
                XCTFail("expected .commandFailed, got \(String(describing: error))")
                return
            }
            XCTAssertEqual(tool, "Custom command")
            XCTAssertEqual(exitCode, 2)
            XCTAssertNil(reason)
            let description = try XCTUnwrap(error?.errorDescription)
            XCTAssertEqual(description, "Custom command exited with code 2")
            for content in [Self.transcript, "stderr marker", "stdout marker"] {
                XCTAssertFalse(description.contains(content), "the error text holds program output: \(description)")
            }
        }

        func testTimeoutStopsASilentProgramAndNamesTheTool() async throws {
            let program = try makeProgram("cat > /dev/null\nsleep 30")
            var generator = custom([program.path])
            generator.timeout = 1

            let error = await generateError(generator, within: 5)

            guard case let .commandTimedOut(tool)? = error else {
                XCTFail("expected .commandTimedOut, got \(String(describing: error))")
                return
            }
            XCTAssertEqual(tool, "Custom command")
        }

        func testRunFolderIsRemovedAfterSuccessAndAfterFailure() async throws {
            for (name, ending) in [("success", "echo 'The protocol'"), ("failure", "exit 1")] {
                let program = try makeProgram("cat > /dev/null\npwd -P > '\(record(name))'\n\(ending)")

                _ = try? await custom([program.path]).generate(transcript: Self.transcript, title: "Sync", diarized: false)

                let folder = try recorded(name).trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertTrue(folder.contains("MeetingTranscriber-cli-"), "\(name): unexpected run folder \(folder)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder), "\(name): the run folder outlived its run")
            }
        }

        // MARK: - Codex preset

        func testCodexTemplateIsPinned() {
            let generator = CommandProtocolGenerator.codex(language: "German")

            XCTAssertEqual(generator.tool, "Codex CLI")
            XCTAssertEqual(generator.arguments, Self.codexTemplate)
            XCTAssertEqual(CommandProtocolGenerator.codex(language: "German", program: "/x/codex").arguments.first, "/x/codex")
        }

        func testCodexReadsTheProtocolFromItsLastMessageFile() async throws {
            let program = try makeProgram("""
            cat > '\(record("stdin"))'
            while [ $# -gt 0 ]; do
                if [ "$1" = "--output-last-message" ]; then out="$2"; fi
                shift
            done
            echo '{"type":"thread.started","thread_id":"t1"}'
            printf 'Codex protocol\\n' > "$out"
            echo '{"type":"turn.completed"}'
            """)

            let result = try await codex(program: program.path).generate(transcript: Self.transcript, title: "Sync", diarized: false)

            XCTAssertEqual(result, "Codex protocol")
            XCTAssertEqual(try recorded("stdin"), Self.pinnedPrompt + Self.transcript)
        }

        func testCodexFailureCarriesCodexsOwnMessageOrTheUpdateHint() async throws {
            let cases: [(body: String, exitCode: Int32, reason: String)] = [
                (
                    #"echo '{"type":"turn.failed","error":{"message":"Quota exceeded"}}'"# + "\nexit 1",
                    1, "Quota exceeded",
                ),
                (
                    "echo \"error: unexpected argument '--ephemeral' found\" >&2\nexit 2",
                    2, CommandProtocolGenerator.codexUpdateHint,
                ),
            ]
            for (body, expectedCode, expectedReason) in cases {
                let program = try makeProgram("cat > /dev/null\n\(body)")

                let error = await generateError(codex(program: program.path))

                guard case let .commandFailed(tool, exitCode, reason)? = error else {
                    XCTFail("expected .commandFailed, got \(String(describing: error))")
                    continue
                }
                XCTAssertEqual(tool, "Codex CLI")
                XCTAssertEqual(exitCode, expectedCode)
                XCTAssertEqual(reason, expectedReason)
                XCTAssertEqual(error?.errorDescription, "Codex CLI exited with code \(expectedCode): \(expectedReason)")
            }
        }

        func testCodexFailureReason() {
            let long = String(repeating: "m", count: 400)
            let cases: [(name: String, stdout: String, stderr: String, expected: String?)] = [
                (
                    "turn.failed wins over error",
                    #"{"type":"turn.failed","error":{"message":"turn"}}"# + "\n" + #"{"type":"error","message":"error"}"#,
                    "", "turn",
                ),
                ("last error event", #"{"type":"error","message":"first"}"# + "\n" + #"{"type":"error","message":"second"}"#, "", "second"),
                ("capped", #"{"type":"error","message":""# + long + #""}"#, "", String(long.prefix(300))),
                ("old Codex", "", "error: unexpected argument '--ephemeral' found", CommandProtocolGenerator.codexUpdateHint),
                ("unknown shapes", "not json\n{\"type\":\"error\"}\n[1]\n{\"type\":\"turn.failed\",\"error\":\"x\"}", "boom", nil),
            ]
            for (name, stdout, stderr, expected) in cases {
                let output = CLIProcessRunner.Output(status: 1, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
                XCTAssertEqual(CommandProtocolGenerator.codexFailureReason(output), expected, name)
            }
        }

        // MARK: - Helpers

        private var promptURL: URL {
            scratch.appendingPathComponent("pinned-prompt.md")
        }

        /// The custom command over `arguments`, reading the pinned prompt.
        private func custom(_ arguments: [String], model: String = "") -> CommandProtocolGenerator {
            var generator = CommandProtocolGenerator.custom(arguments: arguments, model: model, language: "German")
            generator.promptURL = promptURL
            return generator
        }

        /// The Codex preset with `program` in place of `codex`, reading the
        /// pinned prompt.
        private func codex(program: String) -> CommandProtocolGenerator {
            var generator = CommandProtocolGenerator.codex(language: "German", program: program)
            generator.promptURL = promptURL
            return generator
        }

        /// The error `generate()` throws; fails the test when it returns a
        /// protocol instead, throws something else, or has not returned within
        /// `seconds`.
        private func generateError(
            _ generator: CommandProtocolGenerator,
            within seconds: TimeInterval = 10,
            file: StaticString = #filePath,
            line: UInt = #line,
        ) async -> ProtocolError? {
            let returned = XCTestExpectation(description: "generate() returned")
            let run = Task {
                defer { returned.fulfill() }
                return try await generator.generate(transcript: Self.transcript, title: "Sync", diarized: false)
            }
            guard await XCTWaiter.fulfillment(of: [returned], timeout: seconds) == .completed else {
                XCTFail("generate() did not return within \(seconds) s", file: file, line: line)
                return nil
            }
            switch await run.result {
            case let .success(text):
                XCTFail("generate() returned \(text) instead of failing", file: file, line: line)
                return nil

            case let .failure(error as ProtocolError):
                return error

            case let .failure(error):
                XCTFail("unexpected error \(error)", file: file, line: line)
                return nil
            }
        }

        private func makeProgram(_ body: String) throws -> URL {
            let url = scratch.appendingPathComponent("fake-\(UUID().uuidString).sh")
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        /// Path of a file a fake program writes what it saw into.
        private func record(_ name: String) -> String {
            scratch.appendingPathComponent("record-\(name)").path
        }

        private func recorded(_ name: String) throws -> String {
            try String(contentsOfFile: record(name), encoding: .utf8)
        }
    }
#endif
