#if !APPSTORE

    import Foundation

    /// Keeping the user's own Claude Code setup out of a summary run.
    ///
    /// Left to itself the CLI starts a run with what the user set up for
    /// coding: every configured MCP server and the account's claude.ai
    /// connectors, all built-in tools including shell commands, the user's
    /// permission mode, hooks, plugins and global instructions file, and it
    /// sends usage telemetry. The transcript reaches the model as input and
    /// holds whatever was said in the meeting, so with tools in reach a
    /// sentence that reads like an instruction could make the model act. A
    /// summary needs none of it: the prompt arrives on stdin and the protocol
    /// leaves on stdout.
    ///
    /// Measured with CLI 2.1.306: with the options and variables below the
    /// start-up event lists no tools, no MCP servers and no hook events,
    /// reports analytics disabled and permission mode `default`, the CLI's
    /// own sign-in still works, and the input is about 20 times smaller.
    /// `--bare` does most of it in one option but never reads the CLI's
    /// sign-in or keychain, so a subscription login would stop working.
    ///
    /// Ignoring the settings files also drops what the user keeps only there,
    /// a gateway URL in their `env` block for instance; managed settings and
    /// the app's API key field still apply.
    extension ClaudeCLIProtocolGenerator {
        /// An option a run gets only when the CLI's `--help` lists `name`,
        /// as `arguments`: a CLI older than the option rejects it.
        struct IsolationOption {
            let name: String
            let arguments: [String]
        }

        /// No built-in tool (`""` switches them all off), no MCP server but
        /// those of an `--mcp-config` the app never passes, and no user,
        /// project or local settings file.
        static let isolationOptions = [
            IsolationOption(name: "--tools", arguments: ["--tools", ""]),
            IsolationOption(name: "--strict-mcp-config", arguments: ["--strict-mcp-config"]),
            IsolationOption(name: "--setting-sources", arguments: ["--setting-sources", ""]),
        ]

        /// Turns off telemetry, error reports and the CLI's other
        /// nonessential traffic. Set for every run, over any inherited value;
        /// a CLI that does not know it ignores it.
        static let disableNonessentialTrafficVariable = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"

        /// Set to `false` for every run, like the variable above. With
        /// `--strict-mcp-config` it keeps the account's claude.ai connectors
        /// out; the measurement did not separate which of the two does that.
        static let claudeAIMCPServersVariable = "ENABLE_CLAUDEAI_MCP_SERVERS"

        /// Every option the `--help` check looks for: the session flag and
        /// the isolation options.
        static var optionalFlags: Set<String> {
            Set([noSessionPersistenceFlag] + isolationOptions.map(\.name))
        }

        /// Which of `optionalFlags` `help` names. An option counts only as a
        /// whole name, so `--tools-file` does not list `--tools`.
        static func optionsListed(inHelp help: String) -> Set<String> {
            optionalFlags.filter { names($0, in: help) }
        }

        /// The isolation options a run with `listed` goes without, by name,
        /// in their order: what the run's warning names.
        static func missingIsolationOptions(listed: Set<String>) -> [String] {
            isolationOptions.map(\.name).filter { !listed.contains($0) }
        }

        /// Whether `text` holds `option` with no letter, digit or dash on
        /// either side.
        static func names(_ option: String, in text: some StringProtocol) -> Bool {
            let pattern = "(?<![A-Za-z0-9-])\(NSRegularExpression.escapedPattern(for: option))(?![A-Za-z0-9-])"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
    }

#endif
