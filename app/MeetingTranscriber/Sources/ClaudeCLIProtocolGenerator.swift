#if !APPSTORE

    import Foundation
    import os.log

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ClaudeCLIProtocolGenerator")

    /// Claude CLI implementation that generates protocols via subprocess.
    struct ClaudeCLIProtocolGenerator: ProtocolGenerating {
        let claudeBin: String
        let language: String

        /// User-supplied key from Settings → Protocol Generation (`AppSettings.claudeAPIKey`),
        /// injected only when the user has explicitly typed one in. Not
        /// auto-discovered: an implicit switch away from the CLI's own OAuth
        /// login would silently move a healthy subscription session onto
        /// metered billing, and a stale/wrong key would silently break a
        /// previously-working install (both measured — see PR #692 review).
        let anthropicAPIKey: String?

        /// Wall-clock limit for one run.
        let timeout: TimeInterval

        init(
            claudeBin: String,
            language: String,
            anthropicAPIKey: String? = nil,
            timeout: TimeInterval = CLIProcessRunner.defaultTimeout,
        ) {
            self.claudeBin = claudeBin
            self.language = language
            self.anthropicAPIKey = anthropicAPIKey
            self.timeout = timeout
        }

        /// Search paths for Claude CLI binaries: the shared runner's.
        static let searchPaths = CLIProcessRunner.searchPaths

        // MARK: - ProtocolGenerating

        func generate(
            transcript: String,
            title _: String,
            diarized: Bool,
            meetingStartTime: Date?,
        ) async throws -> String {
            let prompt = ProtocolGenerator.fullPrompt(
                transcript: transcript, diarized: diarized, language: language, meetingStartTime: meetingStartTime,
            )

            let launch = await Self.launchConfiguration(claudeBin: claudeBin, anthropicAPIKey: anthropicAPIKey)
            let workingDirectory = try Self.makeWorkingDirectory()
            let projectFolder = Self.cliProjectFolder(workingDirectory: workingDirectory, environment: launch.environment)
            defer { Self.removeRunFolders(workingDirectory: workingDirectory, projectFolder: projectFolder) }

            let promptData = Data(prompt.utf8)
            logger.info("claude_cli_subprocess_start prompt_bytes=\(promptData.count, privacy: .public)")
            let output = try await run(
                CLIProcessRunner.Request(
                    executable: URL(fileURLWithPath: launch.resolvedBin),
                    arguments: launch.arguments,
                    environment: launch.environment,
                    workingDirectory: workingDirectory,
                    standardInput: promptData,
                    timeout: timeout,
                ),
                resolvedBin: launch.resolvedBin,
            )

            // The newline makes a last line the CLI did not terminate count too.
            var buffer = output.stdout
            buffer.append(0x0A)
            var resultEvent: ResultEventInfo?
            let text = Self.drainStreamJSONLines(buffer: &buffer, resultEvent: &resultEvent).joined()

            if output.status != 0 {
                throw Self.handleFailure(
                    exitCode: output.status, stderrData: output.stderr, text: text, resultEvent: resultEvent,
                )
            }

            return try Self.validateGeneratedText(text)
        }

        /// Runs the CLI on the shared runner and turns its failures into the
        /// errors and log lines this provider has always reported.
        private func run(_ request: CLIProcessRunner.Request, resolvedBin: String) async throws -> CLIProcessRunner.Output {
            do {
                return try await CLIProcessRunner.run(request)
            } catch let CLIProcessRunner.Failure.couldNotStart(reason) {
                logger.error(
                    "claude_cli_not_found bin=\(self.claudeBin, privacy: .public) resolvedPath=\(resolvedBin, privacy: .public) error=\(reason, privacy: .public)",
                )
                throw ProtocolError.cliNotFound(claudeBin)
            } catch CLIProcessRunner.Failure.timedOut {
                logger.error("claude_cli_timeout timeout=\(request.timeout, privacy: .public)s")
                throw ProtocolError.timeout
            } catch CLIProcessRunner.Failure.stdoutTooLarge {
                throw ProtocolError.commandOutputTooLarge(tool: "Claude CLI")
            }
        }

        /// Pair an already-decoded stderr string with `exitCode` as a
        /// `ProtocolError.cliFailed`.
        static func makeFailureError(exitCode: Int32, stderrText: String) -> ProtocolError {
            .cliFailed(Int(exitCode), stderrText)
        }

        /// Decodes `stderrData`, logs the raw exit/stderr/text, and builds the
        /// error `generate()` throws on a nonzero exit — pulled out of
        /// `generate()` itself to keep that function's body short.
        static func handleFailure(
            exitCode: Int32, stderrData: Data, text: String, resultEvent: ResultEventInfo?,
        ) -> ProtocolError {
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // The accumulated text is a complete generated protocol on any run
            // that got far enough to produce one (the CLI runs without
            // --include-partial-messages, so only whole assistant messages are
            // ever emitted) — never safe to log at .public. Kept .private,
            // unchanged from the redaction in PR #692's 4th commit.
            logger.error(
                "claude_cli_failed exit=\(exitCode, privacy: .public) stderr=\(stderrText, privacy: .public) text=\(text, privacy: .private)",
            )
            // The terminal result event's own error fields are CLI-authored
            // diagnostic metadata, never generated content by construction —
            // restores the .public visibility PR #692 traded away, for
            // cliFailed AND (via PipelineQueue+Stages.swift's shared catch-all
            // log site) for cliNotFound/timeout/emptyProtocol/OpenAI-provider
            // failures too, none of which ever carried content in the first
            // place.
            let publicMessage = publicFailureMessage(resultEvent: resultEvent, stderrText: stderrText)
            logger.error(
                "claude_cli_failed_reason exit=\(exitCode, privacy: .public) reason=\(publicMessage, privacy: .public)",
            )
            return makeFailureError(exitCode: exitCode, stderrText: publicMessage)
        }

        /// The message surfaced to the user and logged at `.public`. Prefers
        /// the result event's own error text (see `resultEventFailureReason`
        /// — never generated content); then real stderr output (also always
        /// safe — stderr can be empty for a given failure, but never unsafe);
        /// then a fixed placeholder. Deliberately does NOT fall back to the
        /// accumulated `text` — that would reopen the leak PR #692's 4th
        /// commit closed, for the sake of a case not yet observed in
        /// practice (a nonzero exit whose terminal result event carries no
        /// error markers at all).
        static func publicFailureMessage(resultEvent: ResultEventInfo?, stderrText: String) -> String {
            if let reason = resultEventFailureReason(resultEvent) { return reason }
            if !stderrText.isEmpty { return stderrText }
            return "no diagnostic detail available in the CLI's output"
        }

        /// Trim whitespace from CLI output. Throws `.emptyProtocol` when
        /// the subprocess exited successfully but produced no usable text.
        static func validateGeneratedText(_ text: String) throws -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProtocolError.emptyProtocol }
            return trimmed
        }

        // MARK: - Stream JSON

        /// Drain every newline-terminated line currently in `buffer`, parsing
        /// each via `parseStreamJSONLine`. Returns the extracted text
        /// fragments in order. Lines that are empty after trimming, lines
        /// that don't decode as UTF-8, and lines that `parseStreamJSONLine`
        /// rejects are silently skipped. Also captures the last-seen
        /// terminal `result` event (there is only ever one per run) into
        /// `resultEvent` for the caller to read once streaming ends.
        ///
        /// Trailing bytes without a terminating newline stay in `buffer`
        /// for the next call to consume — the caller must keep the buffer
        /// across iterations.
        static func drainStreamJSONLines(buffer: inout Data, resultEvent: inout ResultEventInfo?) -> [String] {
            var fragments: [String] = []
            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex ..< newlineIdx]
                buffer.removeSubrange(buffer.startIndex ... newlineIdx)

                guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !line.isEmpty else { continue }

                if let text = parseStreamJSONLine(line) {
                    fragments.append(text)
                }
                if let parsed = parseResultEvent(line) {
                    resultEvent = parsed
                }
            }
            return fragments
        }

        /// Parse a single stream-json line and extract text content.
        static func parseStreamJSONLine(_ line: String) -> String? {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // content_block_delta carries streaming text chunks
            if obj["type"] as? String == "content_block_delta",
               let delta = obj["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return text
            }

            // assistant message carries the final full text
            if obj["type"] as? String == "assistant",
               let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "text",
                       let text = block["text"] as? String {
                        return text
                    }
                }
            }

            return nil
        }

        /// Content-free diagnostic fields read from a stream-json terminal
        /// `result` event. Unlike the accumulated assistant `text` (a
        /// complete generated protocol on any run that produced one), `errors`
        /// and `terminalReason` are CLI-authored metadata about the run
        /// itself and never carry meeting content, by construction — safe to
        /// log at `.public`.
        ///
        /// `result` is NOT safe on its own: it is a dual-purpose field that
        /// holds the generated protocol on a normal completion and the
        /// error sentence on an in-turn API-error failure (e.g. an expired
        /// OAuth session), and `subtype` reads `"success"` in both cases —
        /// `isError` alone does not prove which one a given event is, only
        /// that the CLI currently behaves this way (undocumented upstream,
        /// github.com/anthropics/claude-code#24612; confirmed against real
        /// runs, both by us and independently by the PR #710 reviewer).
        /// `resultEventFailureReason` additionally requires `terminalReason
        /// == "api_error"` before trusting `result`, so a future CLI version
        /// that ever sets `isError: true` with `result` still holding content
        /// fails closed to the caller's placeholder instead of logging it.
        struct ResultEventInfo: Equatable {
            let isError: Bool
            let errors: [String]
            let result: String?
            let terminalReason: String?
        }

        /// Parse a stream-json terminal `result` line. Returns nil for every
        /// other event type or malformed JSON. `errors` (the structural-
        /// failure shape — error_during_execution, error_max_turns,
        /// error_max_budget_usd, error_max_structured_output_retries) and
        /// `result` (the success shape, which the CLI also uses — with
        /// `is_error: true` — when a run fails immediately with an API
        /// error, e.g. an expired OAuth session or an invalid key on the
        /// first turn) are the two shapes observed in the wild; both are
        /// read defensively since this format is undocumented upstream
        /// (github.com/anthropics/claude-code#24612) and could change.
        /// `terminal_reason` (e.g. `"api_error"`, `"completed"`,
        /// `"max_turns"`) is the CLI's own classification of why the turn
        /// ended — see `ResultEventInfo`'s doc comment for why
        /// `resultEventFailureReason` checks it before trusting `result`.
        static func parseResultEvent(_ line: String) -> ResultEventInfo? {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "result" else {
                return nil
            }
            let isError = obj["is_error"] as? Bool ?? false
            let errors = (obj["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
            let result = obj["result"] as? String
            let terminalReason = obj["terminal_reason"] as? String
            return ResultEventInfo(isError: isError, errors: errors, result: result, terminalReason: terminalReason)
        }

        /// The CLI's own diagnostic sentence for a failed run, sourced from
        /// the terminal `result` event rather than the accumulated assistant
        /// text. Prefers `errors` (joined — always content-free, see
        /// `ResultEventInfo`). Falls back to `result` only when `isError` is
        /// set AND `terminalReason == "api_error"` — the one CLI-classified
        /// reason observed to put its error sentence in the dual-purpose
        /// `result` field rather than `errors`. Any other or missing
        /// `terminalReason` fails closed to nil rather than risk trusting
        /// `result` while it might hold generated content. Returns nil when
        /// the event is absent or carries nothing usable.
        static func resultEventFailureReason(_ resultEvent: ResultEventInfo?) -> String? {
            guard let resultEvent, resultEvent.isError else { return nil }
            if !resultEvent.errors.isEmpty {
                return resultEvent.errors.joined(separator: "; ")
            }
            guard resultEvent.terminalReason == "api_error" else { return nil }
            if let result = resultEvent.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                return result
            }
            return nil
        }

        // MARK: - CLI Resolution

        /// Scan known install locations for executables starting with "claude".
        /// Always includes "claude" as a fallback even if not found.
        static func availableClaudeBinaries() -> [String] {
            let fm = FileManager.default
            var names = Set<String>()

            for dir in searchPaths {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where entry.hasPrefix("claude") {
                    let full = "\(dir)/\(entry)"
                    if fm.isExecutableFile(atPath: full) {
                        names.insert(entry)
                    }
                }
            }

            names.insert("claude")
            return names.sorted()
        }

        /// Resolve the claude CLI binary path.
        /// App bundles have a restricted PATH, so check common install locations.
        static func resolveClaudePath(_ bin: String) -> String {
            // If already an absolute path, use it
            if bin.hasPrefix("/") { return bin }

            for path in searchPaths.map({ "\($0)/\(bin)" })
                where FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            // Fallback: hope it's in PATH
            return "/usr/bin/env"
        }

        // MARK: - Pure subprocess builders

        /// Build the CLI argument vector. When `resolvedBin` is the
        /// `/usr/bin/env` fallback, prepend `claudeBin` so env can resolve
        /// it from PATH. `noSessionPersistence` adds
        /// `noSessionPersistenceFlag`; pass what
        /// `cliSupportsNoSessionPersistence` found for this binary.
        static func buildSubprocessArgs(claudeBin: String, resolvedBin: String, noSessionPersistence: Bool) -> [String] {
            var args = ["-p", "-", "--output-format", "stream-json", "--verbose", "--model", "sonnet"]
            if noSessionPersistence {
                args.append(noSessionPersistenceFlag)
            }
            if resolvedBin == "/usr/bin/env" {
                args.insert(claudeBin, at: 0)
            }
            return args
        }

        /// Strip `CLAUDECODE` (avoid nested-session detection by the child
        /// CLI) and prepend `searchPaths` to `PATH` (app bundles inherit
        /// a minimal `PATH`). `anthropicAPIKey`, when non-empty and not
        /// already set in `baseEnvironment`, is injected so the subprocess
        /// can authenticate via API key instead of the CLI's own OAuth
        /// session. The key is never auto-discovered — it only arrives here
        /// when the user has explicitly typed one into Settings → Protocol
        /// Generation (`AppSettings.claudeAPIKey`), so a healthy OAuth
        /// session is never silently switched to metered billing and a bad
        /// key can never silently break a previously-working install.
        static func buildEnvironment(
            baseEnvironment: [String: String],
            searchPaths: [String],
            anthropicAPIKey: String? = nil,
        ) -> [String: String] {
            var env = CLIProcessRunner.environment(base: baseEnvironment, searchPaths: searchPaths)
            if env["ANTHROPIC_API_KEY"]?.isEmpty ?? true,
               let anthropicAPIKey, !anthropicAPIKey.isEmpty {
                env["ANTHROPIC_API_KEY"] = anthropicAPIKey
            }
            return env
        }

        /// A new, empty, owner-only run folder for one CLI run (see
        /// `CLIProcessRunner.makeRunDirectory`). The CLI needs no folder at
        /// all, the transcript arrives on stdin; it gets one of its own so it
        /// never starts in the app's working directory.
        static func makeWorkingDirectory(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
            try CLIProcessRunner.makeRunDirectory(in: parent)
        }
    }

#endif
