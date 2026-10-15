// swiftlint:disable:this file_name
//
// The file holds the app's half of the mt-update contract (source selection,
// porcelain parser, child environment, the installer seam); none of the types
// alone names it.

import Foundation

/// Whether this build takes its updates from mt-update, the fork's script that
/// merges, builds and replaces `/Applications/MeetingTranscriber-Dev.app`.
/// Every other build keeps the GitHub release check.
enum MtUpdateSource {
    /// Where mt-update is installed, relative to the home folder.
    static let executablePathInHome = ".local/bin/mt-update"
    /// The one bundle mt-update replaces.
    static let installedBundlePath = "/Applications/MeetingTranscriber-Dev.app"

    /// True only for a non-App-Store build with mt-update present that runs as
    /// the bundle mt-update installs. A development build run from a checkout
    /// or the Homebrew release is not that bundle, and replacing it would
    /// install a second app.
    static func isActive(isAppStoreBuild: Bool, executableIsPresent: Bool, runningBundlePath: String) -> Bool {
        guard !isAppStoreBuild, executableIsPresent else { return false }
        return standardized(runningBundlePath) == standardized(installedBundlePath)
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// How an mt-update child ended.
enum MtUpdateExit: Equatable {
    case exited(Int32)
    case signaled(Int32)
}

/// Why a `--check --porcelain` run produced no usable answer.
enum MtUpdateCheckFailure: Equatable {
    /// The answer carries no `format=mt-update-porcelain/1` line: an mt-update
    /// that predates the contract, such as today's human-readable `--check`.
    case unsupported
    /// The format is right but the status is missing, unknown, or disagrees
    /// with the exit code.
    case contradicting
    /// An exit code other than 0 or 10, or a signal.
    case exitStatus(MtUpdateExit)
    /// No answer within the check's time limit.
    case timedOut
    /// The child could not be launched; the reason is the launch error's.
    case notStartable(String)

    /// The message About shows for a failed check. The causes that leave
    /// mt-update output behind point at the check log.
    func message(checkLogPath: String) -> String {
        let details = " Details: \(checkLogPath)"
        return switch self {
        case .unsupported:
            "This mt-update cannot report updates to the app yet."

        case .contradicting:
            "Update check failed: mt-update's answer was incomplete or did not match its exit status." + details

        case let .exitStatus(.exited(code)):
            "Update check failed: mt-update exited with code \(code)." + details

        case let .exitStatus(.signaled(signal)):
            "Update check failed: mt-update was ended by signal \(signal)." + details

        case .timedOut:
            "Update check failed: mt-update did not answer within 5 minutes." + details

        case let .notStartable(reason):
            "Update check failed: mt-update could not be started (\(reason))."
        }
    }
}

/// What one `--check --porcelain` run says.
enum MtUpdateCheckOutcome: Equatable {
    case upToDate
    case updateAvailable(summary: String)
    case failed(MtUpdateCheckFailure)
}

/// Reads the answer of `mt-update --check --porcelain`, per the contract table
/// in the spec. A check counts only when the format line is present and the
/// status agrees with the exit code; everything else is a failed check, so an
/// mt-update that predates the contract (exit 0, human text) never reads as up
/// to date.
enum MtUpdatePorcelain {
    static let format = "mt-update-porcelain/1"
    static let maxSummaryLength = 80
    static let missingSummary = "new build"

    private static let upToDateStatus = "up-to-date"
    private static let updateAvailableStatus = "update-available"
    private static let keys: Set<String> = ["format", "status", "summary"]

    static func parse(exit: MtUpdateExit, output: String) -> MtUpdateCheckOutcome {
        let expectedStatus: String? = switch exit {
        case .exited(0): upToDateStatus
        case .exited(10): updateAvailableStatus
        default: nil
        }
        guard let expectedStatus else { return .failed(.exitStatus(exit)) }

        let fields = fields(in: output)
        guard fields["format"] == format else { return .failed(.unsupported) }
        guard fields["status"] == expectedStatus else { return .failed(.contradicting) }
        guard expectedStatus == updateAvailableStatus else { return .upToDate }

        let summary = (fields["summary"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .updateAvailable(summary: summary.isEmpty ? missingSummary : String(summary.prefix(maxSummaryLength)))
    }

    /// The known `key=value` lines: the key is everything before the first
    /// `=` and must match exactly, the value is the rest of the line, and the
    /// first occurrence of a key wins. `\r\n` is a single newline `Character`,
    /// so CRLF output splits like LF output.
    private static func fields(in output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            guard keys.contains(key), fields[key] == nil else { continue }
            fields[key] = String(line[line.index(after: equals)...])
        }
        return fields
    }
}

/// The environment an mt-update child runs with, check and install alike.
enum MtUpdateEnvironment {
    /// `PATH` when the app has none: what a login shell starts from.
    static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The app's environment minus every `MT_` variable, so mt-update always
    /// runs with its own defaults (reopening the app after an install
    /// included). `PATH` gets `~/.local/bin` and the Homebrew folders in front,
    /// because a launched app inherits a minimal one and mt-update's
    /// self-update looks itself up there; an empty `PATH` counts as none,
    /// since its empty entry would mean the working directory.
    /// `GIT_TERMINAL_PROMPT=0` makes a git credential prompt fail at once
    /// instead of hanging a child that has no terminal.
    static func build(base: [String: String], home: String) -> [String: String] {
        var environment = base.filter { !$0.key.hasPrefix("MT_") }
        let localBin = URL(fileURLWithPath: home, isDirectory: true).appending(path: ".local/bin").path
        let basePath = base["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackPath
        environment["PATH"] = "\(localBin):/opt/homebrew/bin:/usr/local/bin:\(basePath)"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }
}

/// Which build is running: the commit it was built from (`GitCommitHash` in
/// `Info.plist`) and the main executable's modification date. Every mt-update
/// build sets both anew, so a change in either means a new build is running.
struct BuildIdentity: Codable, Equatable {
    let gitCommitHash: String
    let executableModified: Date?
}

/// A started mt-update child. The start time tells it apart from a later
/// process that reuses its ID.
struct MtUpdateLaunch: Codable, Equatable {
    let pid: Int32
    let processStart: Date?
}

/// The seam between `UpdateChecker` and the process that runs mt-update.
protocol MtUpdateInstalling: Sendable {
    /// Where an install's stdout and stderr go.
    var installLogPath: String { get }
    /// Where a check's stdout and stderr go.
    var checkLogPath: String { get }
    /// The build this process runs as.
    func currentBuild() -> BuildIdentity
    /// Runs `mt-update --check --porcelain` and reads its answer.
    func check() async -> MtUpdateCheckOutcome
    /// Starts an install in the background. `onExit` fires once if the child
    /// ends while this app still runs.
    func startInstall(onExit: @escaping @Sendable (MtUpdateExit) -> Void) throws -> MtUpdateLaunch
    /// Whether the recorded child still runs: its ID is alive and its start
    /// time matches.
    func isRunning(_ launch: MtUpdateLaunch) -> Bool
}
