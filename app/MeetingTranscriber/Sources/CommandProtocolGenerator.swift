#if !APPSTORE

    import Foundation
    import os.log

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "CommandProtocolGenerator")

    /// A protocol provider that runs a command-line program on the shared
    /// runner: the Codex CLI preset and the user's custom command. The
    /// argument template follows `CommandTemplate`'s placeholder rules; the
    /// program starts without a shell in a private run folder that holds the
    /// input and output files, and is removed when the run ends.
    ///
    /// The program's stdout and stderr may repeat meeting content, so they
    /// are logged only at `.private` and never become part of an error.
    struct CommandProtocolGenerator: ProtocolGenerating {
        /// Names the provider in errors and logs ("Codex CLI", "Custom command").
        let tool: String
        /// The argument template, program first, as stored.
        let arguments: [String]
        /// The value of `{model}`.
        let model: String
        let language: String
        /// Turns a failed run's output into a content-free reason for the
        /// error, or nil when the tool reports none.
        let failureReason: (@Sendable (CLIProcessRunner.Output) -> String?)?
        var timeout = CLIProcessRunner.defaultTimeout
        /// The most protocol bytes a run may return, from stdout or the output file.
        var maxOutputBytes = CLIProcessRunner.defaultMaxStdoutBytes
        var promptURL = AppPaths.customPromptFile

        static let codexUpdateHint = "This Codex CLI does not know an option the app needs (such as --ephemeral). Update Codex."
        private static let maxReasonLength = 300
        private static let maxLoggedOutputBytes = 2048

        /// The Codex CLI preset. `--ephemeral` keeps the run out of Codex's
        /// session store, `--skip-git-repo-check` lets it run in the run
        /// folder, `--sandbox read-only` keeps the transcript from steering
        /// writes, and `--json` makes its error events readable. Model and
        /// login come from the user's Codex configuration.
        static func codex(language: String, program: String = "codex") -> Self {
            Self(
                tool: "Codex CLI",
                arguments: [
                    program, "exec", "--json", "--ephemeral", "--skip-git-repo-check",
                    "--sandbox", "read-only", "--output-last-message", "{output_file}", "-",
                ],
                model: "",
                language: language,
                failureReason: codexFailureReason,
            )
        }

        static func custom(arguments: [String], model: String, language: String) -> Self {
            Self(tool: "Custom command", arguments: arguments, model: model, language: language, failureReason: nil)
        }

        // MARK: - ProtocolGenerating

        func generate(
            transcript: String,
            title _: String,
            diarized: Bool,
            meetingStartTime: Date?,
        ) async throws -> String {
            let arguments = CommandTemplate.effectiveArguments(self.arguments)
            let model = self.model.trimmingCharacters(in: .whitespacesAndNewlines)
            try CommandTemplate.validate(arguments, model: model)
            let prompt = ProtocolGenerator.fullPrompt(
                transcript: transcript, diarized: diarized, language: language,
                meetingStartTime: meetingStartTime, promptURL: promptURL,
            )
            let environment = CLIProcessRunner.environment(base: ProcessInfo.processInfo.environment)
            let programName = URL(fileURLWithPath: arguments[0]).lastPathComponent
            guard let executable = CLIProcessRunner.resolveProgram(arguments[0], environment: environment) else {
                logger.error("command_not_found tool=\(tool, privacy: .public) program=\(programName, privacy: .public)")
                throw ProtocolError.commandNotFound(tool: tool, program: programName)
            }

            let runDirectory = try CLIProcessRunner.makeRunDirectory()
            defer { try? FileManager.default.removeItem(at: runDirectory) }
            let invocation = try Self.prepare(
                arguments: arguments, model: model, prompt: prompt, transcript: transcript, in: runDirectory,
            )
            let (inputMode, outputMode) = (invocation.inputMode.rawValue, invocation.outputMode.rawValue)
            let stdinBytes = invocation.standardInput?.count ?? 0
            logger.info(
                "command_start tool=\(tool, privacy: .public) program=\(programName, privacy: .public) arguments=\(invocation.arguments.count, privacy: .public) input=\(inputMode, privacy: .public) output=\(outputMode, privacy: .public) stdin_bytes=\(stdinBytes, privacy: .public)",
            )
            let output = try await run(
                CLIProcessRunner.Request(
                    executable: executable,
                    arguments: invocation.arguments,
                    environment: environment,
                    workingDirectory: runDirectory,
                    standardInput: invocation.standardInput,
                    timeout: timeout,
                    maxStdoutBytes: maxOutputBytes,
                ),
                programName: programName,
            )
            return try protocolText(from: output, invocation: invocation)
        }

        // MARK: - Run

        /// The substituted arguments after the program and what goes to the
        /// program's stdin, with the input files written.
        private struct Invocation {
            let arguments: [String]
            let inputMode: CommandTemplate.InputMode
            let outputMode: CommandTemplate.OutputMode
            /// The full prompt in stdin mode, nil (`/dev/null`) otherwise.
            let standardInput: Data?
            /// Where `{output_file}` points; read in file output mode only.
            let outputFile: URL
        }

        /// Writes the input files `arguments` name into `folder`, owner-only,
        /// and substitutes the placeholders. Files nothing names are not written.
        private static func prepare(
            arguments: [String], model: String, prompt: String, transcript: String, in folder: URL,
        ) throws -> Invocation {
            let promptFile = folder.appendingPathComponent("prompt.txt")
            let transcriptFile = folder.appendingPathComponent("transcript.txt")
            let outputFile = folder.appendingPathComponent("protocol.md")
            let promptData = Data(prompt.utf8)
            if CommandTemplate.uses(.promptFile, in: arguments) {
                try writeOwnerOnly(promptData, to: promptFile)
            }
            if CommandTemplate.uses(.transcriptFile, in: arguments) {
                try writeOwnerOnly(Data(transcript.utf8), to: transcriptFile)
            }
            let substituted = CommandTemplate.substitute(arguments, values: [
                .model: model, .promptFile: promptFile.path, .transcriptFile: transcriptFile.path, .outputFile: outputFile.path,
            ])
            let inputMode = CommandTemplate.inputMode(of: arguments)
            let outputMode = CommandTemplate.outputMode(of: arguments)
            return Invocation(
                arguments: Array(substituted.dropFirst()),
                inputMode: inputMode,
                outputMode: outputMode,
                standardInput: inputMode == .stdin ? promptData : nil,
                outputFile: outputFile,
            )
        }

        private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
            try data.write(to: url, options: .withoutOverwriting)
            try FileManager.default.restrictToOwner(url)
        }

        /// Runs the program and turns the runner's failures and a non-zero
        /// exit into tool-named errors.
        private func run(_ request: CLIProcessRunner.Request, programName: String) async throws -> CLIProcessRunner.Output {
            let started = Date()
            let output: CLIProcessRunner.Output
            do {
                output = try await CLIProcessRunner.run(request)
            } catch let CLIProcessRunner.Failure.couldNotStart(reason) {
                logger.error(
                    "command_not_found tool=\(tool, privacy: .public) program=\(programName, privacy: .public) error=\(reason, privacy: .private)",
                )
                throw ProtocolError.commandNotFound(tool: tool, program: programName)
            } catch CLIProcessRunner.Failure.timedOut {
                logger.error("command_timeout tool=\(tool, privacy: .public) elapsed=\(Self.seconds(since: started), privacy: .public)s")
                throw ProtocolError.commandTimedOut(tool: tool)
            } catch CLIProcessRunner.Failure.stdoutTooLarge {
                logger.error("command_output_too_large tool=\(tool, privacy: .public) source=stdout")
                throw ProtocolError.commandOutputTooLarge(tool: tool)
            }
            let elapsed = Self.seconds(since: started)
            guard output.status == 0 else {
                logger.error(
                    "command_failed tool=\(tool, privacy: .public) exit=\(output.status, privacy: .public) elapsed=\(elapsed, privacy: .public)s",
                )
                logger.error(
                    "command_failed_output stdout=\(Self.logExcerpt(output.stdout), privacy: .private) stderr=\(Self.logExcerpt(output.stderr), privacy: .private)",
                )
                throw ProtocolError.commandFailed(tool: tool, exitCode: output.status, reason: failureReason?(output))
            }
            logger.info("command_done tool=\(tool, privacy: .public) exit=0 elapsed=\(elapsed, privacy: .public)s")
            return output
        }

        // MARK: - Output

        /// The protocol: the output file's content, or stdout when the
        /// template names no output file; decoded with invalid UTF-8
        /// replaced, trimmed, and never empty.
        private func protocolText(from output: CLIProcessRunner.Output, invocation: Invocation) throws -> String {
            var data = output.stdout
            if invocation.outputMode == .file {
                switch Self.readOutputFile(at: invocation.outputFile, maxBytes: maxOutputBytes) {
                case let .read(contents):
                    data = contents

                case .tooLarge:
                    logger.error("command_output_too_large tool=\(tool, privacy: .public) source=file")
                    throw ProtocolError.commandOutputTooLarge(tool: tool)

                case .unusable:
                    logger.error("command_no_protocol tool=\(tool, privacy: .public) output=file reason=unusable")
                    throw ProtocolError.commandProducedNoProtocol(tool: tool)
                }
            }
            let text = Self.lossyText(data).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                let source = invocation.outputMode.rawValue
                logger.error("command_no_protocol tool=\(tool, privacy: .public) output=\(source, privacy: .public) reason=empty")
                throw ProtocolError.commandProducedNoProtocol(tool: tool)
            }
            return text
        }

        private enum OutputFile {
            case read(Data)
            /// More than the cap.
            case tooLarge
            /// Missing, a symlink, or not a regular file.
            case unusable
        }

        /// Reads the output file the program wrote, at most `maxBytes`. It is
        /// opened without following a symlink and without blocking, so a
        /// FIFO cannot hang the run, and read only when the opened descriptor
        /// is a regular file.
        private static func readOutputFile(at url: URL, maxBytes: Int) -> OutputFile {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { return .unusable }
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return .unusable }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while data.count <= maxBytes {
                let wanted = min(buffer.count, maxBytes + 1 - data.count)
                let (count, error) = buffer.withUnsafeMutableBytes { (read(descriptor, $0.baseAddress, wanted), errno) }
                if count < 0, error == EINTR { continue }
                guard count >= 0 else { return .unusable }
                if count == 0 { break }
                data.append(contentsOf: buffer[0 ..< count])
            }
            return data.count > maxBytes ? .tooLarge : .read(data)
        }

        // MARK: - Codex

        /// Codex's own reason for a failed run, read from its `--json`
        /// events: the message of the last `turn.failed` event, else of the
        /// last `error` event; else, for a Codex too old for an option the
        /// preset passes, `codexUpdateHint`. Capped in length; nil when
        /// nothing matches.
        static func codexFailureReason(_ output: CLIProcessRunner.Output) -> String? {
            var turnFailure: String?
            var errorEvent: String?
            for line in lossyText(output.stdout).split(whereSeparator: \.isNewline) {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "turn.failed":
                    turnFailure = nonEmpty((event["error"] as? [String: Any])?["message"]) ?? turnFailure

                case "error":
                    errorEvent = nonEmpty(event["message"]) ?? errorEvent

                default:
                    continue
                }
            }
            let stderr = lossyText(output.stderr)
            let reason = turnFailure ?? errorEvent ?? (stderr.contains("unexpected argument") ? codexUpdateHint : nil)
            return reason.map { String($0.prefix(maxReasonLength)) }
        }

        private static func nonEmpty(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }

        // MARK: - Logging

        private static func logExcerpt(_ data: Data) -> String {
            lossyText(data.prefix(maxLoggedOutputBytes))
        }

        /// `data` as UTF-8 with invalid sequences replaced, so one bad byte
        /// does not lose the whole text (hence not the failable initializer).
        private static func lossyText(_ data: Data) -> String {
            // swiftlint:disable:next optional_data_string_conversion
            String(decoding: data, as: UTF8.self)
        }

        private static func seconds(since start: Date) -> String {
            String(format: "%.1f", Date().timeIntervalSince(start))
        }
    }

#endif
