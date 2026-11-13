#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The Codex CLI preset starts nothing from the user's Codex
    /// configuration beyond the model and the login: every configured MCP
    /// server is switched off by name, and so are connectors, plugins and
    /// the notify hook. Run against a `#!/bin/sh` fake that answers the
    /// server listing and records what each start received.
    final class CommandProtocolGeneratorCodexIsolationTests: XCTestCase {
        /// The preset's arguments after the program, with the output file's
        /// path in place of the placeholder, and without the server override.
        private static let presetArguments = [
            "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
            "--disable", "apps", "--disable", "plugins", "-c", "notify=[]",
            "--output-last-message", "{output_file}", "-",
        ]

        /// R6: every server the listing names is switched off in one table
        /// value right after `exec`, each name a quoted TOML key, so a dot,
        /// a quote, a backslash or a placeholder in a name stays part of it.
        /// The listing runs with the same program in the same run folder and
        /// environment as the run.
        func testCodexSwitchesOffEveryConfiguredServerItsAppsPluginsAndNotify() async throws {
            let folder = try makeTempDirectory(prefix: "codex-isolation")
            let listing = folder.appendingPathComponent("listing.json")
            try #"[{"name":"plain","enabled":true},{"name":"dot.name","enabled":false},{"name":"quo\"te\\back"},{"name":"{output_file}"}]"#
                .write(to: listing, atomically: true, encoding: .utf8)
            let codex = try makeCodex(in: folder, listing: "cat '\(listing.path)'")

            let result = try await generate(codex)

            XCTAssertEqual(result, "Codex protocol")
            XCTAssertEqual(try codex.recorded("listing-args"), ["mcp", "list", "--json"])
            XCTAssertEqual(try codex.recorded("listing-dir"), try codex.recorded("run-dir"))
            XCTAssertEqual(try codex.recorded("listing-env"), try codex.recorded("run-env"))
            var expected = Self.presetArguments
            expected.insert(
                contentsOf: [
                    "-c",
                    #"mcp_servers={"plain"={enabled=false},"dot.name"={enabled=false},"quo\"te\\back"={enabled=false},"{output_file}"={enabled=false}}"#,
                ],
                at: 1,
            )
            XCTAssertEqual(try codex.runArguments(), expected)
        }

        /// R6's error case, and a configuration without servers: no server
        /// override, the rest of the preset unchanged, and the run goes ahead.
        func testCodexRunsWithoutAServerOverrideWhenTheListingNamesNoServer() async throws {
            let cases: [(name: String, listing: String)] = [
                ("no servers configured", "echo '[]'"),
                ("listing fails", "echo 'error: unknown command' >&2; exit 2"),
                ("not JSON", "echo 'no servers'"),
                ("an entry without a name", #"echo '[{"name":"plain"},{"enabled":true}]'"#),
            ]
            for (name, listing) in cases {
                let codex = try makeCodex(in: makeTempDirectory(prefix: "codex-isolation"), listing: listing)

                let result = try await generate(codex)

                XCTAssertEqual(result, "Codex protocol", name)
                XCTAssertEqual(try codex.recorded("listing-args"), ["mcp", "list", "--json"], name)
                XCTAssertEqual(try codex.runArguments(), Self.presetArguments, name)
            }
        }

        /// The custom command is the user's own: no listing, no added argument,
        /// even when the program it names is Codex.
        func testTheCustomCommandGetsNoListingAndNoAddedArgument() async throws {
            let folder = try makeTempDirectory(prefix: "codex-isolation")
            let codex = try makeCodex(in: folder, listing: "echo '[{\"name\":\"plain\"}]'")
            let generator = CommandProtocolGenerator.custom(arguments: [codex.path, "exec", "-"], model: "", language: "German")

            let result = try await generator.generate(
                transcript: "Speaker 1: hello", title: "Sync", diarized: false, meetingStartTime: nil,
                instructions: ProtocolInstructions(template: "PINNED PROMPT\n", background: nil),
            )

            XCTAssertEqual(result, "stdout protocol")
            XCTAssertFalse(FileManager.default.fileExists(atPath: codex.file("listing-args").path), "the custom command was listed")
            XCTAssertEqual(try codex.recorded("run-args"), ["exec", "-"])
        }

        /// A control character in a name is escaped too, so the table value
        /// stays one valid TOML value.
        func testServerNamesWithControlCharactersStayQuotedKeys() {
            XCTAssertEqual(CommandProtocolGenerator.tomlQuoted("tab\there\nnl\u{7F}"), #""tab\u0009here\u000Anl\u007F""#)
        }

        // MARK: - Helpers

        private struct FakeCodex {
            let path: String
            let folder: URL

            func file(_ name: String) -> URL {
                folder.appendingPathComponent(name)
            }

            /// The lines the fake wrote to `name`.
            func recorded(_ name: String) throws -> [String] {
                try String(contentsOf: file(name), encoding: .utf8).components(separatedBy: "\n").dropLast()
                    .filter { !$0.hasPrefix("_=") }
            }

            /// The run's arguments, the output file's path back as its placeholder.
            func runArguments() throws -> [String] {
                var arguments = try recorded("run-args")
                if let flag = arguments.firstIndex(of: "--output-last-message"), flag + 1 < arguments.count {
                    arguments[flag + 1] = "{output_file}"
                }
                return arguments
            }
        }

        /// A fake `codex`. `mcp …` records its arguments, folder and
        /// environment and then runs `listing`; any other start records the
        /// same, drains stdin, writes `Codex protocol` to the file after
        /// `--output-last-message` and prints `stdout protocol`.
        private func makeCodex(in folder: URL, listing: String) throws -> FakeCodex {
            let record = { (name: String) in folder.appendingPathComponent(name).path }
            let path = try makeExecutableScript(in: folder, name: "codex", body: """
            if [ "$1" = "mcp" ]; then
                printf '%s\\n' "$@" > '\(record("listing-args"))'
                pwd -P > '\(record("listing-dir"))'
                env | sort > '\(record("listing-env"))'
                \(listing)
                exit $?
            fi
            printf '%s\\n' "$@" > '\(record("run-args"))'
            pwd -P > '\(record("run-dir"))'
            env | sort > '\(record("run-env"))'
            cat > /dev/null
            while [ $# -gt 0 ]; do
                if [ "$1" = "--output-last-message" ]; then out="$2"; fi
                shift
            done
            if [ -n "$out" ]; then printf 'Codex protocol\\n' > "$out"; fi
            echo 'stdout protocol'
            """)
            return FakeCodex(path: path, folder: folder)
        }

        private func generate(_ codex: FakeCodex) async throws -> String {
            try await CommandProtocolGenerator.codex(language: "German", program: codex.path).generate(
                transcript: "Speaker 1: hello", title: "Sync", diarized: false, meetingStartTime: nil,
                instructions: ProtocolInstructions(template: "PINNED PROMPT\n", background: nil),
            )
        }
    }
#endif
