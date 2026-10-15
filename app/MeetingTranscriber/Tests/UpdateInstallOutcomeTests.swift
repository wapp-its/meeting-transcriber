import Foundation
@testable import MeetingTranscriber
import XCTest

/// What an mt-update install leaves behind and how it is reported: the
/// pending-install record, the outcome of a live exit, the launch-time
/// evaluation after a restart, the notification texts and the install gate.
final class UpdateInstallOutcomeTests: XCTestCase {
    private let oldBuild = BuildIdentity(
        gitCommitHash: "65888b5",
        executableModified: Date(timeIntervalSinceReferenceDate: 812_000_000.25),
    )
    private let launch = MtUpdateLaunch(pid: 4242, processStart: Date(timeIntervalSinceReferenceDate: 812_000_100.125))

    private func pending(wasWatching: Bool = true) -> PendingUpdateInstall {
        PendingUpdateInstall(
            startedAt: Date(timeIntervalSinceReferenceDate: 812_000_100.5),
            launch: launch,
            previousBuild: oldBuild,
            summary: "upstream 1a2b3c4 · wapp/main 5d6e7f8",
            wasWatching: wasWatching,
        )
    }

    // MARK: - Live exit

    func testALiveExitMapsToItsOutcome() {
        let cases: [(MtUpdateExit, UpdateInstallOutcome)] = [
            (.exited(0), .finishedWithoutRestart),
            (.exited(2), .mergeConflict),
            (.exited(3), .buildFailed),
            (.exited(4), .busyOrNotQuittable),
            (.exited(1), .failed(.exited(1))),
            (.exited(10), .failed(.exited(10))),
            (.signaled(9), .failed(.signaled(9))),
        ]
        for (exit, expected) in cases {
            XCTAssertEqual(UpdateInstallOutcome.forLiveExit(exit), expected, "\(exit)")
        }
    }

    // MARK: - Launch evaluation

    func testNothingPendingIsNothingToReport() {
        XCTAssertEqual(
            UpdateLaunchEvaluation.evaluate(pending: nil, currentBuild: oldBuild) { _ in true },
            .nothingPending,
        )
    }

    /// A different build is the success, decided before liveness: an
    /// mt-update still exiting must not delay it. The commit or the
    /// executable's modification date changing is enough, and watching is
    /// restored exactly when it was on at the start.
    func testADifferentBuildIsInstalledEvenWhileMtUpdateStillRuns() {
        let newCommit = BuildIdentity(gitCommitHash: "5d6e7f8", executableModified: oldBuild.executableModified)
        let newExecutable = BuildIdentity(
            gitCommitHash: oldBuild.gitCommitHash,
            executableModified: Date(timeIntervalSinceReferenceDate: 812_000_900),
        )
        for current in [newCommit, newExecutable] {
            for wasWatching in [true, false] {
                XCTAssertEqual(
                    UpdateLaunchEvaluation.evaluate(pending: pending(wasWatching: wasWatching), currentBuild: current) { _ in true },
                    .report(.installed(summary: "upstream 1a2b3c4 · wapp/main 5d6e7f8"), restoreWatching: wasWatching),
                    "\(current), wasWatching \(wasWatching)",
                )
            }
        }
    }

    /// The same build: the recorded process decides between still running
    /// and did not finish, and it is the recorded launch that gets asked.
    func testTheSameBuildIsStillRunningOrDidNotFinish() {
        var asked: [MtUpdateLaunch] = []
        let running = UpdateLaunchEvaluation.evaluate(pending: pending(), currentBuild: oldBuild) { recorded in
            asked.append(recorded)
            return true
        }
        let gone = UpdateLaunchEvaluation.evaluate(pending: pending(), currentBuild: oldBuild) { _ in false }

        XCTAssertEqual(running, .stillRunning(pending()))
        XCTAssertEqual(asked, [launch])
        XCTAssertEqual(gone, .report(.didNotFinish, restoreWatching: false))
    }

    // MARK: - Store

    func testTheStoreRoundTripsClearsAndDropsUndecodableData() throws {
        let suiteName = "UpdateInstallOutcomeTests-\(getpid())-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { DefaultsSuite.remove(suiteName) }
        let store = PendingUpdateInstallStore(defaults: defaults)

        XCTAssertNil(store.load())
        store.save(pending())
        XCTAssertEqual(store.load(), pending())
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertNil(defaults.object(forKey: "mtUpdatePendingInstall"))

        for undecodable: Any in [Data("not a record".utf8), "a string"] {
            defaults.set(undecodable, forKey: "mtUpdatePendingInstall")
            XCTAssertNil(store.load(), "\(undecodable)")
            XCTAssertNil(defaults.object(forKey: "mtUpdatePendingInstall"), "removed: \(undecodable)")
        }
    }

    // MARK: - Notices

    /// Every outcome's text, verbatim. Pinning the whole text also pins that
    /// none carries a date or time.
    func testEveryOutcomeHasItsNotice() {
        let log = "/Users/u/Library/Logs/MeetingTranscriber/mt-update.log"
        let unchanged = "The installed app is unchanged. Details: \(log)"
        let cases: [(UpdateInstallOutcome, String, String)] = [
            (
                .installed(summary: "upstream 1a2b3c4 · wapp/main 5d6e7f8"),
                "Update installed",
                "Now running the new build: upstream 1a2b3c4 · wapp/main 5d6e7f8.",
            ),
            (
                .finishedWithoutRestart,
                "Update installed",
                "mt-update finished without restarting the app. Quit and reopen Meeting Transcriber to use the new build.",
            ),
            (.mergeConflict, "Update not installed", "mt-update hit a merge conflict. \(unchanged)"),
            (.buildFailed, "Update not installed", "mt-update could not build the new version. \(unchanged)"),
            (
                .busyOrNotQuittable,
                "Update not installed",
                "mt-update gave up: the app stayed busy too long or could not be quit. \(unchanged)",
            ),
            (.failed(.exited(7)), "Update not installed", "mt-update failed with exit code 7. \(unchanged)"),
            (.failed(.signaled(9)), "Update not installed", "mt-update was ended by signal 9. \(unchanged)"),
            (
                .notStartable("mt-update was not found"),
                "Update not installed",
                "mt-update could not be started (mt-update was not found). The installed app is unchanged.",
            ),
            (
                .didNotFinish,
                "Update did not finish",
                "mt-update ended without installing a new build, so this is still the previous build. Details: \(log)",
            ),
        ]
        for (outcome, title, body) in cases {
            let notice = UpdateInstallNotice(outcome: outcome, logPath: log)
            XCTAssertEqual(notice.title, title, "\(outcome)")
            XCTAssertEqual(notice.body, body, "\(outcome)")
        }
    }

    // MARK: - Install gate

    func testTheGateNamesWhyAnInstallIsNotPossible() {
        let recording = "Not available while recording."
        let processing = "Not available while meetings are being processed."
        let cases: [(name: String, reason: String?, state: (recording: Bool, starting: Bool, waiting: Int, active: Int))] = [
            ("recording", recording, (true, false, 0, 0)),
            ("manual recording starting", recording, (false, true, 0, 0)),
            ("recording while jobs run", recording, (true, false, 1, 1)),
            ("a job waiting", processing, (false, false, 1, 0)),
            ("a job being processed", processing, (false, false, 0, 2)),
            ("idle", nil, (false, false, 0, 0)),
        ]
        for testCase in cases {
            XCTAssertEqual(
                UpdateInstallGate.blockedReason(
                    isRecording: testCase.state.recording,
                    manualRecordingStarting: testCase.state.starting,
                    waitingJobs: testCase.state.waiting,
                    activeJobs: testCase.state.active,
                ),
                testCase.reason,
                testCase.name,
            )
        }
    }
}
