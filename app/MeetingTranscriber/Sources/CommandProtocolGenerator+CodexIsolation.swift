#if !APPSTORE

    import Foundation
    import os.log

    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "CommandProtocolGenerator")

    /// Keeping the user's Codex setup out of a Codex CLI summary run, apart
    /// from the model, the reasoning effort and the login.
    ///
    /// Left to itself `codex exec` starts every MCP server of the user's
    /// configuration, offers its connectors (apps) and plugins, and runs the
    /// configured notify command after the turn. The transcript reaches the
    /// model as input and holds whatever was said in the meeting, so none of
    /// that may be in reach. `--ignore-user-config` drops all of it at once,
    /// and the user's model and reasoning effort with it, which Settings
    /// says come from Codex's configuration.
    ///
    /// Apps, plugins and notify are switched off in the preset's template.
    /// The servers cannot be switched off there: Codex merges a
    /// `-c mcp_servers=…` table over the configured one, so an empty table
    /// clears nothing. Each run therefore lists the configured servers first
    /// and switches every one off by name. Measured with Codex CLI 0.162.1
    /// against sentinel servers and a sentinel notify command: with these
    /// overrides none of them ran, without them all of them did. The table
    /// goes after `exec`: given in front of it, it was ignored.
    ///
    /// The listing is not silent: for a server reached over HTTP it asks the
    /// server's host whether it offers a sign-in (discovery requests, no MCP
    /// session), measured against a local stand-in server. The run itself
    /// then contacts none of them.
    extension CommandProtocolGenerator {
        /// How long `codex mcp list --json` may take before the run goes
        /// ahead without switching the servers off.
        static let codexServerListingTimeout: TimeInterval = 10

        /// `-c` and one table value that switch off every MCP server the
        /// user's Codex configuration names, for the run `setup` describes,
        /// or nothing when none is configured. The names come from
        /// `mcp list --json`, run with the same program, environment and run
        /// folder. A listing that fails or cannot be read adds nothing and
        /// logs a content-free warning; the run goes ahead.
        static func codexServerOverride(for setup: RunSetup) async -> [String] {
            let listing: CLIProcessRunner.Output
            do {
                listing = try await CLIProcessRunner.run(CLIProcessRunner.Request(
                    executable: setup.executable,
                    arguments: ["mcp", "list", "--json"],
                    environment: setup.environment,
                    workingDirectory: setup.directory,
                    standardInput: nil,
                    timeout: codexServerListingTimeout,
                ))
            } catch {
                warnThatServersStayOn(reason: listingFailure(error))
                return []
            }
            guard listing.status == 0 else {
                warnThatServersStayOn(reason: "exit_\(listing.status)")
                return []
            }
            guard let names = try? codexServerNames(fromListing: listing.stdout) else {
                warnThatServersStayOn(reason: "unreadable")
                return []
            }
            return names.isEmpty ? [] : ["-c", codexServerOverride(names: names)]
        }

        /// The server names in `mcp list --json` output: an array of
        /// objects, each with a string `name`. Throws for anything else.
        static func codexServerNames(fromListing data: Data) throws -> [String] {
            struct Server: Decodable {
                let name: String
            }
            return try JSONDecoder().decode([Server].self, from: data).map(\.name)
        }

        /// `mcp_servers={"<name>"={enabled=false},…}`, each name a quoted
        /// TOML key, so a dot or any other character a bare key does not
        /// allow stays part of the name. The dotted form
        /// `mcp_servers.<name>.enabled=false` would not do: Codex splits it
        /// on every dot, and a run with a server named `review.name` failed.
        static func codexServerOverride(names: [String]) -> String {
            "mcp_servers={" + names.map { "\(tomlQuoted($0))={enabled=false}" }.joined(separator: ",") + "}"
        }

        /// `value` as a TOML basic string: in double quotes, with `"` and
        /// `\` escaped and every control character as `\uXXXX`.
        static func tomlQuoted(_ value: String) -> String {
            var quoted = "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"", "\\":
                    quoted += "\\" + String(scalar)

                case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                    quoted += String(format: "\\u%04X", scalar.value)

                default:
                    quoted.unicodeScalars.append(scalar)
                }
            }
            return quoted + "\""
        }

        /// A fixed name for why the listing ended without output; never the
        /// launch error's text, which can hold a path.
        private static func listingFailure(_ error: any Error) -> String {
            switch error as? CLIProcessRunner.Failure {
            case .couldNotStart: "could_not_start"
            case .timedOut: "timed_out"
            case .stdoutTooLarge: "output_too_large"
            case nil: "failed"
            }
        }

        private static func warnThatServersStayOn(reason: String) {
            logger.warning(
                "command_isolation_incomplete tool=Codex CLI missing=mcp_servers reason=\(reason, privacy: .public) — the run may start the MCP servers of the user's Codex configuration",
            )
        }
    }

#endif
