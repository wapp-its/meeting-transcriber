#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// A summary run gets the prompt and nothing else from the user's own
    /// Claude Code setup: no tools, no MCP servers, no settings files, no
    /// nonessential traffic. Each option goes in only when the CLI's `--help`
    /// lists it, so an older CLI still runs.
    final class ClaudeCLIProtocolGeneratorIsolationTests: XCTestCase {
        private static let base = ["-p", "-", "--output-format", "stream-json", "--verbose", "--model", "sonnet"]
        private static let noSessionPersistence = "--no-session-persistence"
        private static let isolation = ["--tools", "", "--strict-mcp-config", "--setting-sources", ""]

        /// Option lines as the CLI's `--help` prints them (2.1.322).
        private static let help = [
            "--no-session-persistence": "  --no-session-persistence              Disable session persistence - sessions",
            "--tools": "  --tools <tools...>                    Specify the list of available tools from",
            "--strict-mcp-config": "  --strict-mcp-config                   Only use MCP servers from --mcp-config,",
            "--setting-sources": "  --setting-sources <sources>           Comma-separated list of setting sources",
        ]

        // MARK: - Arguments

        /// R1-R3, each with its error case: an option the help lists reaches
        /// the CLI, one it does not list stays out and the run goes ahead. An
        /// option the help names only as part of a longer one is not listed.
        func testEachIsolationOptionGoesInOnlyWhenTheHelpListsIt() async throws {
            let cases: [(name: String, help: [String], expected: [String])] = [
                ("all listed", Self.lines("--tools", "--strict-mcp-config", "--setting-sources"), Self.isolation),
                ("tools only", Self.lines("--tools"), ["--tools", ""]),
                ("MCP and settings only", Self.lines("--strict-mcp-config", "--setting-sources"), [
                    "--strict-mcp-config", "--setting-sources", "",
                ]),
                ("none listed", Self.lines(), []),
                ("longer names only", Self.lines() + [
                    "  --tools-file <path>                   Read the tool list from a file",
                    "  --strict-mcp-configs                  Not the option",
                    "  --setting-sources-file <file>         Not the option either",
                ], []),
            ]
            for (name, help, expected) in cases {
                let cli = try makeCLI(help: help)

                let result = try await generate(cli)

                XCTAssertEqual(result, "Protocol", name)
                XCTAssertEqual(try cli.runArguments(), Self.base + [Self.noSessionPersistence] + expected, name)
                let listed = ClaudeCLIProtocolGenerator.optionsListed(inHelp: help.joined(separator: "\n"))
                XCTAssertEqual(
                    ClaudeCLIProtocolGenerator.missingIsolationOptions(listed: listed),
                    ["--tools", "--strict-mcp-config", "--setting-sources"].filter { !expected.contains($0) },
                    "\(name): the run's warning names the options left out",
                )
            }
        }

        // MARK: - Environment

        /// R2 (claude.ai connectors) and R4: both variables are set over any
        /// value the app inherited.
        func testTheIsolationVariablesOverrideInheritedValues() {
            let env = ClaudeCLIProtocolGenerator.buildEnvironment(
                baseEnvironment: [
                    "PATH": "/usr/bin",
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "0",
                    "ENABLE_CLAUDEAI_MCP_SERVERS": "true",
                ],
                searchPaths: [],
            )

            XCTAssertEqual(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
            XCTAssertEqual(env["ENABLE_CLAUDEAI_MCP_SERVERS"], "false")
        }

        /// R5 for the app's API key: the key and the model still reach the
        /// CLI, beside every isolation option and variable.
        func testAnAPIKeyRunKeepsItsKeyAndModelBesideTheIsolation() async throws {
            let cli = try makeCLI(
                help: Self.lines("--tools", "--strict-mcp-config", "--setting-sources"),
                reply: "$ANTHROPIC_API_KEY|$CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC|$ENABLE_CLAUDEAI_MCP_SERVERS",
            )

            let result = try await ClaudeCLIProtocolGenerator(
                claudeBin: cli.path, language: "German", anthropicAPIKey: "sk-ant-test-key", clock: ManualClock(),
            ).generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)

            XCTAssertEqual(result, "sk-ant-test-key|1|false")
            XCTAssertEqual(try cli.runArguments(), Self.base + [Self.noSessionPersistence] + Self.isolation)
        }

        // MARK: - A CLI that refuses an option

        /// The yes from `--help` is remembered for every option, so an older
        /// CLI installed at the same path that refuses one of them is asked
        /// again, and the protocol comes from a run with what its help lists.
        func testACLIThatRefusesARememberedOptionIsAskedAgainAndRunWithout() async throws {
            let cli = try makeCLI(help: Self.lines("--tools", "--strict-mcp-config", "--setting-sources"))
            _ = try await generate(cli)

            _ = try makeCLI(at: cli, help: Self.lines("--strict-mcp-config", "--setting-sources"), refuses: ["--tools"])
            let result = try await generate(cli)

            XCTAssertEqual(result, "Protocol")
            XCTAssertEqual(try cli.calls(), ["help", "run", "run", "help", "run"])
            XCTAssertEqual(
                try cli.runArguments(),
                Self.base + [Self.noSessionPersistence, "--strict-mcp-config", "--setting-sources", ""],
            )
        }

        /// The second run gets only what the fresh help lists; when it is
        /// refused too, the run fails with the CLI's own message, and there
        /// is no third run.
        func testARetryThatIsRefusedTooFailsWithTheCLIsMessage() async throws {
            let cli = try makeCLI(help: Self.lines("--tools", "--strict-mcp-config", "--setting-sources"))
            _ = try await generate(cli)

            _ = try makeCLI(
                at: cli, help: Self.lines("--strict-mcp-config", "--setting-sources"),
                refuses: ["--tools", "--strict-mcp-config"],
            )
            do {
                let result = try await generate(cli)
                XCTFail("the run should have failed, returned \(result)")
            } catch let ProtocolError.cliFailed(code, message) {
                XCTAssertEqual(code, 1)
                XCTAssertEqual(message, "error: unknown option '--strict-mcp-config'")
            }

            XCTAssertEqual(try cli.calls(), ["help", "run", "run", "help", "run"])
        }

        // MARK: - Helpers

        /// The help text listing session persistence and `options`.
        private static func lines(_ options: String...) -> [String] {
            ([noSessionPersistence] + options).compactMap { help[$0] }
        }

        /// A fake `claude` and what it recorded.
        private struct FakeCLI {
            let path: String
            let folder: URL

            /// Every start, in order: `help` for a `--help` probe, `run` for a protocol run.
            func calls() throws -> [String] {
                try String(contentsOf: folder.appendingPathComponent("calls.log"), encoding: .utf8)
                    .split(separator: "\n").map(String.init)
            }

            /// The arguments of the last protocol run, one per entry.
            func runArguments() throws -> [String] {
                let text = try String(contentsOf: folder.appendingPathComponent("arguments"), encoding: .utf8)
                return Array(text.components(separatedBy: "\n").dropLast())
            }
        }

        private func makeCLI(help: [String], reply: String = "Protocol") throws -> FakeCLI {
            let folder = try makeTempDirectory(prefix: "claude-isolation")
            return try makeCLI(at: FakeCLI(path: folder.appendingPathComponent("claude").path, folder: folder), help: help, reply: reply)
        }

        /// Writes the fake as a new file over any earlier one, as an installer
        /// replacing a binary does. `--help` prints `help`; a run records its
        /// arguments, fails with an unknown-option message on stderr for the
        /// first option in `refuses` it was given, and otherwise drains stdin
        /// and replies with `reply` as one stream-json text.
        @discardableResult
        private func makeCLI(at cli: FakeCLI, help: [String], refuses: [String] = [], reply: String = "Protocol") throws -> FakeCLI {
            let log = cli.folder.appendingPathComponent("calls.log").path
            let arguments = cli.folder.appendingPathComponent("arguments").path
            let helpOutput = help.map { "printf '%s\\n' '\($0)'" }.joined(separator: "\n")
            let refusals = refuses.map { option in
                """
                for arg in "$@"; do
                    if [ "$arg" = '\(option)' ]; then printf '%s\\n' "error: unknown option '\(option)'" >&2; exit 1; fi
                done
                """
            }.joined(separator: "\n")
            let body = """
            #!/bin/sh
            if [ "$1" = "--help" ]; then
                echo help >> '\(log)'
                \(helpOutput)
                exit 0
            fi
            echo run >> '\(log)'
            printf '%s\\n' "$@" > '\(arguments)'
            \(refusals)
            cat > /dev/null
            printf '{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}\\n' "\(reply)"

            """
            try body.write(toFile: cli.path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
            return cli
        }

        /// On a clock that never moves, so the `--help` probe cannot run out
        /// on a slow runner and change what the run is given.
        private func generate(_ cli: FakeCLI) async throws -> String {
            try await ClaudeCLIProtocolGenerator(claudeBin: cli.path, language: "German", clock: ManualClock())
                .generate(transcript: "Speaker 1: hello", title: "Sync", diarized: false)
        }
    }
#endif
