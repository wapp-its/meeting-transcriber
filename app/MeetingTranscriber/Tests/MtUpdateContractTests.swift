@testable import MeetingTranscriber
import XCTest

/// The app's half of the mt-update contract: which build uses mt-update, how
/// a `--check --porcelain` answer is read, what the child's environment is,
/// and the wording of a failed check. Pure functions, so every row of the
/// spec's contract table is pinned here without starting a process.
final class MtUpdateContractTests: XCTestCase {
    private struct ParseCase {
        let name: String
        let exit: MtUpdateExit
        let output: String
        let expected: MtUpdateCheckOutcome
    }

    private func assertParses(_ cases: [ParseCase], file: StaticString = #filePath, line: UInt = #line) {
        for testCase in cases {
            XCTAssertEqual(
                MtUpdatePorcelain.parse(exit: testCase.exit, output: testCase.output),
                testCase.expected,
                testCase.name,
                file: file,
                line: line,
            )
        }
    }

    private let porcelainFormat = "format=mt-update-porcelain/1"

    // MARK: - Porcelain parser

    /// The two answers the app acts on: exit 10 with `update-available` and
    /// exit 0 with `up-to-date`.
    func testAcceptedAnswersAreReadAsAvailableOrUpToDate() {
        assertParses([
            ParseCase(
                name: "exit 10, update available",
                exit: .exited(10),
                output: "\(porcelainFormat)\nstatus=update-available\nsummary=upstream 1a2b3c4 · wapp/main 5d6e7f8\n",
                expected: .updateAvailable(summary: "upstream 1a2b3c4 · wapp/main 5d6e7f8"),
            ),
            ParseCase(
                name: "exit 0, up to date",
                exit: .exited(0),
                output: "\(porcelainFormat)\nstatus=up-to-date\n",
                expected: .upToDate,
            ),
        ])
    }

    /// Today's `mt-update --check` (R3): German text wrapped in ANSI bold,
    /// exit 0. It must read as an mt-update that cannot report updates yet,
    /// never as up to date. Verbatim from `origin/tools:mt-update.sh`'s `say`.
    func testTodaysHumanCheckOutputIsUnsupported() {
        let todays = "\u{1B}[1mStand jetzt:        upstream 9b5f674 | wapp/main 65888b5\u{1B}[0m\n"
            + "\u{1B}[1mLetzter Build:      upstream 1111111 | wapp/main 2222222\u{1B}[0m\n"
            + "\u{1B}[1mNeuer Stand verfügbar → mt-update\u{1B}[0m\n"

        XCTAssertEqual(MtUpdatePorcelain.parse(exit: .exited(0), output: todays), .failed(.unsupported))
    }

    /// Every answer that is not one of the two accepted ones is a failed
    /// check, never an update and never "up to date".
    func testAnythingButAnAgreeingAnswerIsAFailedCheck() {
        assertParses([
            ParseCase(
                name: "a foreign format version",
                exit: .exited(0),
                output: "format=mt-update-porcelain/2\nstatus=up-to-date\n",
                expected: .failed(.unsupported),
            ),
            ParseCase(
                name: "exit 0 claiming an update",
                exit: .exited(0),
                output: "\(porcelainFormat)\nstatus=update-available\nsummary=x\n",
                expected: .failed(.contradicting),
            ),
            ParseCase(
                name: "exit 10 claiming up to date",
                exit: .exited(10),
                output: "\(porcelainFormat)\nstatus=up-to-date\n",
                expected: .failed(.contradicting),
            ),
            ParseCase(
                name: "no status line",
                exit: .exited(10),
                output: "\(porcelainFormat)\nsummary=x\n",
                expected: .failed(.contradicting),
            ),
            ParseCase(
                name: "an unknown status",
                exit: .exited(0),
                output: "\(porcelainFormat)\nstatus=maybe\n",
                expected: .failed(.contradicting),
            ),
            ParseCase(
                name: "another exit code, even with a valid answer",
                exit: .exited(1),
                output: "\(porcelainFormat)\nstatus=up-to-date\n",
                expected: .failed(.exitStatus(.exited(1))),
            ),
            ParseCase(
                name: "ended by a signal",
                exit: .signaled(15),
                output: "\(porcelainFormat)\nstatus=update-available\n",
                expected: .failed(.exitStatus(.signaled(15))),
            ),
        ])
    }

    /// The summary is trimmed, defaults to `new build` and is cut to 80
    /// characters, counted as Swift `Character`s (a letter with a combining
    /// accent is one).
    func testTheSummaryIsTrimmedDefaultedAndCut() {
        let available = "\(porcelainFormat)\nstatus=update-available\n"
        let accented = String(repeating: "e\u{301}", count: 90)
        assertParses([
            ParseCase(
                name: "missing summary",
                exit: .exited(10),
                output: available,
                expected: .updateAvailable(summary: "new build"),
            ),
            ParseCase(
                name: "blank summary",
                exit: .exited(10),
                output: available + "summary=   \n",
                expected: .updateAvailable(summary: "new build"),
            ),
            ParseCase(
                name: "padded summary",
                exit: .exited(10),
                output: available + "summary=  upstream 1a2b3c4  \n",
                expected: .updateAvailable(summary: "upstream 1a2b3c4"),
            ),
            ParseCase(
                name: "over-long summary",
                exit: .exited(10),
                output: available + "summary=\(String(repeating: "a", count: 81))b\n",
                expected: .updateAvailable(summary: String(repeating: "a", count: 80)),
            ),
            ParseCase(
                name: "over-long summary of combined characters",
                exit: .exited(10),
                output: available + "summary=\(accented)\n",
                expected: .updateAvailable(summary: String(repeating: "e\u{301}", count: 80)),
            ),
        ])
    }

    /// Lines mt-update may print besides the porcelain ones: its self-update
    /// line, unknown keys, CRLF endings. Keys match exactly, the first
    /// occurrence wins, and a value is everything after the first `=`.
    func testOtherLinesAreIgnoredAndOnlyTheFirstKnownKeyCounts() {
        assertParses([
            ParseCase(
                name: "a leading self-update line and unknown keys",
                exit: .exited(10),
                output: "\u{1B}[1mmt-update wurde aktualisiert, starte neu …\u{1B}[0m\n"
                    + "hint=run mt-update\n\(porcelainFormat)\nbranches=3\nstatus=update-available\nsummary=s\n",
                expected: .updateAvailable(summary: "s"),
            ),
            ParseCase(
                name: "CRLF line endings",
                exit: .exited(0),
                output: "\(porcelainFormat)\r\nstatus=up-to-date\r\n",
                expected: .upToDate,
            ),
            ParseCase(
                name: "the first status wins",
                exit: .exited(0),
                output: "\(porcelainFormat)\nstatus=up-to-date\nstatus=update-available\n",
                expected: .upToDate,
            ),
            ParseCase(
                name: "keys are case-sensitive",
                exit: .exited(0),
                output: "\(porcelainFormat)\nStatus=up-to-date\n",
                expected: .failed(.contradicting),
            ),
            ParseCase(
                name: "a value keeps later equals signs",
                exit: .exited(10),
                output: "\(porcelainFormat)\nstatus=update-available\nsummary=a=b\n",
                expected: .updateAvailable(summary: "a=b"),
            ),
        ])
    }

    // MARK: - Failure wording

    func testFailedCheckMessagesNameTheCause() {
        let log = "/Users/u/Library/Logs/MeetingTranscriber/mt-update-check.log"
        let cases: [(MtUpdateCheckFailure, String)] = [
            (.unsupported, "This mt-update cannot report updates to the app yet."),
            (
                .contradicting,
                "Update check failed: mt-update's answer was incomplete or did not match its exit status. Details: \(log)",
            ),
            (.exitStatus(.exited(1)), "Update check failed: mt-update exited with code 1. Details: \(log)"),
            (.exitStatus(.signaled(9)), "Update check failed: mt-update was ended by signal 9. Details: \(log)"),
            (.timedOut, "Update check failed: mt-update did not answer within 5 minutes. Details: \(log)"),
            (
                .notStartable("mt-update was not found"),
                "Update check failed: mt-update could not be started (mt-update was not found).",
            ),
        ]
        for (failure, expected) in cases {
            XCTAssertEqual(failure.message(checkLogPath: log), expected, "\(failure)")
        }
    }

    // MARK: - Source selection

    func testOnlyTheInstalledDevBuildWithMtUpdateUsesIt() {
        let installed = "/Applications/MeetingTranscriber-Dev.app"
        let cases: [(name: String, expected: Bool, build: (appStore: Bool, present: Bool, path: String))] = [
            ("installed dev build with mt-update", true, (false, true, installed)),
            ("trailing slash", true, (false, true, installed + "/")),
            ("App Store build", false, (true, true, installed)),
            ("no mt-update", false, (false, false, installed)),
            ("Homebrew release", false, (false, true, "/Applications/MeetingTranscriber.app")),
            ("development build in a checkout", false, (false, true, "/Users/u/Sources/mt/MeetingTranscriber-Dev.app")),
        ]
        for testCase in cases {
            XCTAssertEqual(
                MtUpdateSource.isActive(
                    isAppStoreBuild: testCase.build.appStore,
                    executableIsPresent: testCase.build.present,
                    runningBundlePath: testCase.build.path,
                ),
                testCase.expected,
                testCase.name,
            )
        }
    }

    // MARK: - Child environment

    func testTheChildEnvironmentDropsMtVariablesAndPrefixesPath() {
        let base = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/u",
            "MT_SKIP_REOPEN": "1",
            "MT_WAIT_MAX": "10",
            "NOT_MT_KEPT": "yes",
            "GIT_TERMINAL_PROMPT": "1",
        ]

        let env = MtUpdateEnvironment.build(base: base, home: "/Users/u")

        XCTAssertEqual(env, [
            "PATH": "/Users/u/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": "/Users/u",
            "NOT_MT_KEPT": "yes",
            "GIT_TERMINAL_PROMPT": "0",
        ])
    }

    /// A launched app may carry no `PATH` at all; the child then gets the
    /// system default after the prefix. An empty one is treated the same,
    /// since its empty entry would put the working directory on `PATH`.
    func testAMissingOrEmptyPathFallsBackToTheSystemDefault() {
        let expected = "/Users/u/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for base in [[:], ["PATH": ""]] {
            let env = MtUpdateEnvironment.build(base: base, home: "/Users/u")
            XCTAssertEqual(env["PATH"], expected, "base \(base)")
            XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0", "base \(base)")
        }
    }
}
