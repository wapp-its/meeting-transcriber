#if !APPSTORE

    import Foundation
    import os

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ClaudeCLIProtocolGenerator")

    /// Keeping the meeting out of the Claude CLI's own session store.
    ///
    /// Left to itself the CLI saves every run as a session under
    /// `~/.claude/projects/<working directory>/`, and a session holds the
    /// whole prompt, which here is the meeting transcript. That is a second,
    /// unplanned copy of a confidential document in another program's folder,
    /// one per protocol since every run has a working directory of its own.
    /// `--no-session-persistence` stops it. What the flag still leaves behind,
    /// measured with CLI 2.1.289, is the project folder itself with an empty
    /// `memory` folder in it. `disableAutoMemoryVariable` keeps the CLI from
    /// creating that folder at all; `removeIfOnlyEmptyFolders` takes it away
    /// where a CLI creates it anyway.
    extension ClaudeCLIProtocolGenerator {
        static let noSessionPersistenceFlag = "--no-session-persistence"

        /// Turns the CLI's auto memory off for the run. Measured with CLI
        /// 2.1.312: with it set, neither the project folder nor its `memory`
        /// folder appears. Unlike the cleanup it also covers a `claude-*`
        /// wrapper that sets its own `CLAUDE_CONFIG_DIR`, as long as the
        /// wrapper passes its environment on. A CLI that does not know the
        /// variable ignores it.
        static let disableAutoMemoryVariable = "CLAUDE_CODE_DISABLE_AUTO_MEMORY"

        /// How long `--help` may take before the CLI is treated as one
        /// without the options it would list.
        static let helpProbeTimeoutSeconds: TimeInterval = 10

        /// The `optionalFlags` each binary's `--help` was last seen to list,
        /// keyed by resolved path and name. A yes is remembered so that a
        /// later `--help` that times out cannot start a meeting without an
        /// option the CLI has. The probe is skipped only once every option
        /// was seen, so a no is asked again on the next run. A run refused
        /// an option drops what was remembered.
        private static let optionsListedByBinary = OSAllocatedUnfairLock<[String: Set<String>]>(initialState: [:])

        typealias LaunchConfiguration = (resolvedBin: String, arguments: [String], environment: [String: String])

        /// Executable, arguments and environment for one run. The session
        /// flag and each isolation option go in only when `--help` lists
        /// them, since a CLI older than an option rejects it; a help text
        /// that cannot be read lists only what was remembered, which keeps
        /// the behaviour from before the options existed.
        func launchConfiguration() async -> LaunchConfiguration {
            let resolvedBin = Self.resolveClaudePath(claudeBin)
            let environment = Self.buildEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment,
                searchPaths: Self.searchPaths,
                anthropicAPIKey: anthropicAPIKey,
            )
            let answer = await askHelp(resolvedBin: resolvedBin, environment: environment)
            if !answer.listed.contains(Self.noSessionPersistenceFlag), !Task.isCancelled {
                logger.warning(
                    "claude_cli_session_persistence_on helpRead=\(answer.helpRead, privacy: .public) — the CLI keeps this run's session, transcript included",
                )
            }
            Self.warnAboutMissingIsolation(answer)
            let arguments = Self.buildSubprocessArgs(claudeBin: claudeBin, resolvedBin: resolvedBin, options: answer.listed)
            return (resolvedBin, arguments, environment)
        }

        /// The launch for one more run after `failed` was refused `refused`,
        /// or nil for none. Drops what was remembered and asks `--help`
        /// again: only a help text that was read and lists none of the
        /// refused options earns a second run, with what that help lists and
        /// the same executable and environment.
        func launchWithoutRefusedOptions(_ refused: Set<String>, after failed: LaunchConfiguration) async -> LaunchConfiguration? {
            let key = Self.cacheKey(resolvedBin: failed.resolvedBin, claudeBin: claudeBin)
            _ = Self.optionsListedByBinary.withLock { $0.removeValue(forKey: key) }
            let answer = await askHelp(resolvedBin: failed.resolvedBin, environment: failed.environment)
            let retry = answer.helpRead && answer.listed.isDisjoint(with: refused)
            logger.warning(
                "claude_cli_rejected_option options=\(refused.sorted().joined(separator: ","), privacy: .public) helpRead=\(answer.helpRead, privacy: .public) retry=\(retry, privacy: .public)",
            )
            guard retry else { return nil }
            Self.warnAboutMissingIsolation(answer)
            let arguments = Self.buildSubprocessArgs(claudeBin: claudeBin, resolvedBin: failed.resolvedBin, options: answer.listed)
            return (failed.resolvedBin, arguments, failed.environment)
        }

        private static func cacheKey(resolvedBin: String, claudeBin: String) -> String {
            "\(resolvedBin)\u{0}\(claudeBin)"
        }

        /// What `--help` says about `optionalFlags`.
        struct HelpAnswer {
            /// The options the help lists; when it could not be read, those
            /// remembered from an earlier help.
            let listed: Set<String>
            /// Whether `listed` comes from a help text that was read.
            let helpRead: Bool
        }

        /// One content-free warning naming the isolation options `answer`
        /// leaves out, if any.
        private static func warnAboutMissingIsolation(_ answer: HelpAnswer) {
            let missing = missingIsolationOptions(listed: answer.listed)
            guard !missing.isEmpty, !Task.isCancelled else { return }
            logger.warning(
                "claude_cli_isolation_incomplete missing=\(missing.joined(separator: ","), privacy: .public) helpRead=\(answer.helpRead, privacy: .public) — the run keeps that part of the user's Claude Code setup",
            )
        }

        /// What the CLI's `--help` says about `optionalFlags`, or what was
        /// remembered when that is all of them. The probe is bounded like a
        /// run: `helpProbeTimeout` on the generator's clock, then its
        /// termination grace.
        private func askHelp(resolvedBin: String, environment: [String: String]) async -> HelpAnswer {
            let key = Self.cacheKey(resolvedBin: resolvedBin, claudeBin: claudeBin)
            let remembered = Self.optionsListedByBinary.withLock { $0[key] } ?? []
            if remembered == Self.optionalFlags { return HelpAnswer(listed: remembered, helpRead: true) }
            let help = await readHelp(resolvedBin: resolvedBin, environment: environment)
            // A probe ended by a cancelled job says nothing about the CLI;
            // the job ends right after.
            guard let help, !Task.isCancelled else { return HelpAnswer(listed: remembered, helpRead: false) }
            let listed = Self.optionsListed(inHelp: help)
            _ = Self.optionsListedByBinary.withLock { $0.updateValue(listed, forKey: key) }
            return HelpAnswer(listed: listed, helpRead: true)
        }

        /// A failed run whose CLI refused `options`. `error` is what the run
        /// reports when there is no second run.
        struct OptionsRefused: Error {
            let options: Set<String>
            let error: ProtocolError
        }

        /// The `optionalFlags` a run given them was refused: those that a
        /// line of its stderr or reported message names together with
        /// unknown-option wording, ignoring case. Both are read because the
        /// message prefers a result event's reason over stderr.
        static func refusedOptions(stderr: String, message: String, arguments: [String]) -> Set<String> {
            let wordings = ["unknown option", "unrecognized option", "unrecognised option", "invalid option"]
            let refusals = [stderr, message].flatMap { $0.split(whereSeparator: \.isNewline) }
                .map { $0.lowercased() }
                .filter { line in wordings.contains { line.contains($0) } }
            return optionalFlags.filter { option in
                arguments.contains(option) && refusals.contains { names(option, in: $0) }
            }
        }

        /// Removes the run's working directory, and the CLI's project folder
        /// for it while that holds nothing but empty folders.
        static func removeRunFolders(workingDirectory: URL, projectFolder: URL?) {
            try? FileManager.default.removeItem(at: workingDirectory)
            if let projectFolder { removeIfOnlyEmptyFolders(projectFolder) }
        }

        /// The CLI's `--help` output, or nil when it could not be started or
        /// did not exit within `helpProbeTimeout`. Runs in a working directory of its
        /// own, like a real run, so the probe neither inherits the app's
        /// directory nor touches the one the real run is about to get.
        ///
        /// Output goes to a file in that directory rather than a pipe, so a
        /// child of the CLI holding its output open cannot hold up the
        /// protocol. A probe still running at `helpProbeTimeout` on `clock` is
        /// stopped (SIGTERM, then SIGKILL after `terminationGrace`) and its
        /// exit awaited before the directory is removed, so the probe takes
        /// at most that limit plus the grace. Cancellation stops it the same
        /// way.
        func readHelp(resolvedBin: String, environment: [String: String]) async -> String? {
            guard let directory = try? Self.makeWorkingDirectory() else { return nil }
            defer { try? FileManager.default.removeItem(at: directory) }
            let outputFile = directory.appendingPathComponent("help.txt")
            guard FileManager.default.createFile(atPath: outputFile.path, contents: nil),
                  let output = try? FileHandle(forWritingTo: outputFile) else { return nil }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolvedBin)
            process.arguments = (resolvedBin == "/usr/bin/env" ? [claudeBin] : []) + ["--help"]
            process.environment = environment
            process.currentDirectoryURL = directory
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            let outcome = try? await BoundedProcess(process, terminationGrace: terminationGrace, clock: clock)
                .run(timeout: helpProbeTimeout)
            try? output.close()
            guard case .exited = outcome, let data = try? Data(contentsOf: outputFile) else { return nil }
            return String(bytes: data, encoding: .utf8)
        }

        /// The folder the CLI keeps for a run started in `workingDirectory`:
        /// `<config dir>/projects/<name>`, where the config dir is
        /// `CLAUDE_CONFIG_DIR` or `.claude` in the child's `HOME` (the app's
        /// home directory when the environment sets none), and the name is the directory's
        /// physical path with every character other than an ASCII letter or
        /// digit replaced by `-`. Nil when the path cannot be resolved.
        static func cliProjectFolder(workingDirectory: URL, environment: [String: String]) -> URL? {
            guard let resolved = realpath(workingDirectory.path, nil) else { return nil }
            defer { free(resolved) }
            let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            let configDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: home).appendingPathComponent(".claude")
            return configDirectory
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(projectFolderName(forPath: String(cString: resolved)), isDirectory: true)
        }

        static func projectFolderName(forPath path: String) -> String {
            String(String.UnicodeScalarView(path.unicodeScalars.map { scalar in
                scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? scalar : "-"
            }))
        }

        /// Removes `folder` only while everything in it is an empty folder.
        /// A file anywhere below it, a session from a CLI without the flag
        /// for instance, keeps the whole folder: the CLI wrote it, and
        /// deleting it is not this app's call.
        ///
        /// The folders go one by one, deepest first, with `rmdir`, which
        /// refuses a folder that is not empty. A file the CLI writes after
        /// the check, while a timed-out run is still shutting down for
        /// instance, therefore keeps its folders instead of going with them.
        static func removeIfOnlyEmptyFolders(_ folder: URL) {
            let own = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard own?.isDirectory == true, own?.isSymbolicLink != true else { return }
            guard let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            ) else { return }
            var folders: [URL] = []
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { return }
                folders.append(item)
            }
            // The enumerator lists a folder before its contents.
            for item in folders.reversed() {
                _ = rmdir(item.path)
            }
            if rmdir(folder.path) != 0 {
                let code = errno
                logger.warning("claude_cli_project_folder_kept errno=\(code, privacy: .public)")
            }
        }
    }

#endif
