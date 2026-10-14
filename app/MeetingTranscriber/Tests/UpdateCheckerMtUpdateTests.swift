@testable import MeetingTranscriber
import XCTest

/// `UpdateChecker` in mt-update mode, driven through `MockMtUpdateInstaller`:
/// the check's mapping, the install guards and record, the live exit, the
/// launch-time report, and the `AppState` wiring around them. GitHub mode is
/// `UpdateCheckerTests`, unchanged.
@MainActor
final class UpdateCheckerMtUpdateTests: XCTestCase {
    private static let summary = "upstream 1a2b3c4 · wapp/main 5d6e7f8"
    private static let newBuild = BuildIdentity(gitCommitHash: "9f8e7d6", executableModified: Date(timeIntervalSince1970: 5000))

    private struct Fixture {
        let checker: UpdateChecker
        let installer: MockMtUpdateInstaller
        let notifier: RecordingNotifier
        let store: PendingUpdateInstallStore
        let provider: MockUpdateProvider
    }

    // MARK: - Check

    func testACheckMapsEachOutcomeAndAFailureKeepsAnEarlierBuild() async throws {
        let failures: [MtUpdateCheckFailure] = [
            .unsupported, .contradicting, .exitStatus(.exited(1)), .exitStatus(.signaled(15)), .timedOut, .notStartable("no such file"),
        ]
        let checkLogPath = MockMtUpdateInstaller().checkLogPath
        let rows: [(outcome: MtUpdateCheckOutcome, summary: String?, error: String?, checked: Bool)] =
            [(.upToDate, nil, nil, true), (.updateAvailable(summary: Self.summary), Self.summary, nil, true)]
                + failures.map { (.failed($0), "earlier build", $0.message(checkLogPath: checkLogPath), false) }

        for row in rows {
            let label = "\(row.outcome)"
            let fixture = try makeFixture()
            fixture.installer.checkOutcome = row.outcome
            fixture.checker.availableBuildSummary = "earlier build"
            fixture.checker.lastError = "an earlier check failure"
            fixture.checker.lastInstallError = "an earlier install failure"

            fixture.checker.checkNow(includePreReleases: true)
            XCTAssertTrue(fixture.checker.isChecking, label)
            await waitFor(!fixture.checker.isChecking, timeout: .seconds(2))

            XCTAssertEqual(fixture.installer.checkCalls, 1, label)
            XCTAssertFalse(fixture.provider.latestReleaseCalled || fixture.provider.allReleasesCalled, label)
            XCTAssertEqual(fixture.checker.availableBuildSummary, row.summary, label)
            XCTAssertEqual(fixture.checker.hasAvailableUpdate, row.summary != nil, label)
            XCTAssertEqual(fixture.checker.lastError, row.error, label)
            XCTAssertEqual(fixture.checker.lastCheckDate != nil, row.checked, label)
            XCTAssertNil(fixture.checker.lastInstallError, label)
        }
    }

    func testACheckIsRefusedWhileInstalling() async throws {
        let fixture = try makeFixture()
        fixture.checker.availableBuildSummary = Self.summary
        fixture.checker.installNow(blockedReason: nil, isWatching: false)
        XCTAssertTrue(fixture.checker.isInstalling)

        fixture.checker.checkNow()
        await Task.yield()

        XCTAssertFalse(fixture.checker.isChecking)
        XCTAssertEqual(fixture.installer.checkCalls, 0)
    }

    // MARK: - Install

    func testInstallNowRefusesWithoutABuildWhileBusyAndWhenBlocked() throws {
        let rows: [(name: String, arrange: @MainActor (UpdateChecker) -> Void, blockedReason: String?)] = [
            ("no build", { $0.availableBuildSummary = nil }, nil),
            ("installing", { $0.installState = .installing(since: Date()) }, nil),
            ("checking", { $0.isChecking = true }, nil),
            ("blocked", { _ in }, "Not available while recording."),
        ]
        for row in rows {
            let fixture = try makeFixture()
            fixture.checker.availableBuildSummary = Self.summary
            row.arrange(fixture.checker)

            fixture.checker.installNow(blockedReason: row.blockedReason, isWatching: true)

            XCTAssertEqual(fixture.installer.startInstallCalls, 0, row.name)
            XCTAssertNil(fixture.store.load(), row.name)
            XCTAssertTrue(fixture.notifier.calls.isEmpty, row.name)
        }
    }

    func testInstallNowStartsTheInstallerAndSavesTheRecord() throws {
        for isWatching in [true, false] {
            let fixture = try makeFixture()
            fixture.checker.availableBuildSummary = Self.summary
            fixture.checker.lastInstallError = "an earlier install failure"
            let before = Date()

            fixture.checker.installNow(blockedReason: nil, isWatching: isWatching)

            XCTAssertEqual(fixture.installer.startInstallCalls, 1)
            let record = try XCTUnwrap(fixture.store.load())
            XCTAssertGreaterThanOrEqual(record.startedAt, before)
            XCTAssertLessThanOrEqual(record.startedAt, Date())
            XCTAssertEqual(record.launch, fixture.installer.launch)
            XCTAssertEqual(record.previousBuild, fixture.installer.build)
            XCTAssertEqual(record.summary, Self.summary)
            XCTAssertEqual(record.wasWatching, isWatching)
            XCTAssertEqual(fixture.checker.installState, .installing(since: record.startedAt))
            XCTAssertNil(fixture.checker.lastInstallError)
            XCTAssertTrue(fixture.notifier.calls.isEmpty)
        }
    }

    func testEachLiveExitPostsOneNoticeClearsTheRecordAndReturnsToIdle() async throws {
        let rows: [(exit: MtUpdateExit, title: String, failed: Bool)] = [
            (.exited(2), "Update not installed", true),
            (.exited(3), "Update not installed", true),
            (.exited(4), "Update not installed", true),
            (.exited(9), "Update not installed", true),
            (.signaled(15), "Update not installed", true),
            (.exited(0), "Update installed", false),
        ]
        for row in rows {
            let label = "\(row.exit)"
            let fixture = try makeFixture()
            fixture.checker.availableBuildSummary = Self.summary
            fixture.checker.installNow(blockedReason: nil, isWatching: false)
            XCTAssertNotNil(fixture.store.load(), label)

            fixture.installer.exit(row.exit)
            await waitFor(!fixture.checker.isInstalling, timeout: .seconds(2))

            XCTAssertEqual(fixture.notifier.calls.count, 1, label)
            let call = try XCTUnwrap(fixture.notifier.calls.first, label)
            let logPath = fixture.installer.installLogPath
            XCTAssertEqual(call.title, row.title, label)
            XCTAssertEqual(call.body, UpdateInstallNotice(outcome: .forLiveExit(row.exit), logPath: logPath).body, label)
            XCTAssertEqual(call.urgency, .standard, label)
            XCTAssertNil(fixture.store.load(), label)
            XCTAssertEqual(fixture.checker.installState, .idle, label)
            if row.failed {
                XCTAssertTrue(call.body.contains(logPath), label)
                XCTAssertEqual(fixture.checker.lastInstallError, call.body, label)
                XCTAssertEqual(fixture.checker.availableBuildSummary, Self.summary, label)
                // Install is offered again.
                fixture.checker.installNow(blockedReason: nil, isWatching: false)
                XCTAssertEqual(fixture.installer.startInstallCalls, 2, label)
            } else {
                XCTAssertNil(fixture.checker.lastInstallError, label)
                XCTAssertNil(fixture.checker.availableBuildSummary, label)
            }
        }
    }

    func testALaunchThatThrowsPostsNotStartableAndSavesNothing() throws {
        let fixture = try makeFixture()
        fixture.installer.launchError = MockMtUpdateInstaller.LaunchFailed()
        fixture.checker.availableBuildSummary = Self.summary

        fixture.checker.installNow(blockedReason: nil, isWatching: true)

        XCTAssertEqual(fixture.notifier.calls.map(\.title), ["Update not installed"])
        let body = try XCTUnwrap(fixture.notifier.calls.first?.body)
        XCTAssertTrue(body.contains("could not be started (launch refused)"), body)
        XCTAssertEqual(fixture.checker.lastInstallError, body)
        XCTAssertNil(fixture.store.load())
        XCTAssertEqual(fixture.checker.installState, .idle)
        XCTAssertEqual(fixture.checker.availableBuildSummary, Self.summary)
    }

    // MARK: - Launch

    func testANewBuildAtLaunchReportsInstalledOnceAndReturnsTheWatchingFlag() throws {
        for wasWatching in [true, false] {
            let fixture = try makeFixture()
            fixture.store.save(pendingRecord(for: fixture.installer, wasWatching: wasWatching))
            fixture.installer.build = Self.newBuild

            XCTAssertEqual(fixture.checker.resumeAfterLaunch(), wasWatching)
            XCTAssertEqual(fixture.notifier.calls.map(\.title), ["Update installed"])
            XCTAssertEqual(fixture.notifier.calls.first?.body.contains(Self.summary), true)
            XCTAssertNil(fixture.store.load())
            XCTAssertEqual(fixture.checker.installState, .idle)

            // Once per instance: a record that turns up later waits for the next launch.
            fixture.store.save(pendingRecord(for: fixture.installer, wasWatching: wasWatching))
            XCTAssertFalse(fixture.checker.resumeAfterLaunch())
            XCTAssertEqual(fixture.notifier.calls.count, 1)
            XCTAssertNotNil(fixture.store.load())
        }
    }

    func testTheSameBuildWithMtUpdateGoneAtLaunchDidNotFinish() throws {
        let fixture = try makeFixture()
        fixture.store.save(pendingRecord(for: fixture.installer, wasWatching: true))

        XCTAssertFalse(fixture.checker.resumeAfterLaunch())

        XCTAssertEqual(fixture.notifier.calls.map(\.title), ["Update did not finish"])
        let body = try XCTUnwrap(fixture.notifier.calls.first?.body)
        XCTAssertTrue(body.contains(fixture.installer.installLogPath), body)
        XCTAssertNil(fixture.store.load())
        XCTAssertEqual(fixture.checker.installState, .idle)
        XCTAssertEqual(fixture.checker.lastInstallError, body)

        // The build that did not install is on offer again, without a check.
        XCTAssertEqual(fixture.checker.availableBuildSummary, Self.summary)
        fixture.checker.installNow(blockedReason: nil, isWatching: false)
        XCTAssertEqual(fixture.installer.startInstallCalls, 1)
    }

    func testAnInstallStillRunningAtLaunchIsRecheckedUntilItHasGone() async throws {
        let fixture = try makeFixture(recheckInterval: .milliseconds(50))
        let record = pendingRecord(for: fixture.installer, wasWatching: false)
        fixture.store.save(record)
        fixture.installer.isInstallRunning = true

        XCTAssertFalse(fixture.checker.resumeAfterLaunch())
        XCTAssertEqual(fixture.checker.installState, .installing(since: record.startedAt))
        // Several rechecks still find it running.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(fixture.checker.isInstalling)
        XCTAssertTrue(fixture.notifier.calls.isEmpty)
        XCTAssertNotNil(fixture.store.load())

        fixture.installer.isInstallRunning = false
        await waitFor(!fixture.checker.isInstalling, timeout: .seconds(2))

        XCTAssertEqual(fixture.notifier.calls.map(\.title), ["Update did not finish"])
        XCTAssertNil(fixture.store.load())
        XCTAssertEqual(fixture.checker.installState, .idle)
        XCTAssertEqual(fixture.checker.availableBuildSummary, Self.summary)
        fixture.checker.checkNow()
        await waitFor(!fixture.checker.isChecking, timeout: .seconds(2))
        XCTAssertEqual(fixture.installer.checkCalls, 1)
    }

    func testNothingIsReportedWithoutARecordOrOutsideMtUpdateMode() throws {
        let fixture = try makeFixture()
        XCTAssertFalse(fixture.checker.resumeAfterLaunch())
        XCTAssertTrue(fixture.notifier.calls.isEmpty)
        XCTAssertEqual(fixture.checker.installState, .idle)

        // A build without mt-update leaves the record for the next mt-update launch.
        let store = try makeStore()
        store.save(pendingRecord(for: fixture.installer, wasWatching: true))
        let notifier = RecordingNotifier()
        let github = UpdateChecker(provider: MockUpdateProvider(), notifier: notifier, pendingStore: store)
        XCTAssertFalse(github.resumeAfterLaunch())
        XCTAssertTrue(notifier.calls.isEmpty)
        XCTAssertNotNil(store.load())
    }

    // MARK: - AppState wiring

    func testAppStateRefusesAnInstallWhileAJobWaits() throws {
        let fixture = try makeFixture()
        fixture.checker.availableBuildSummary = Self.summary
        let state = try makeAppState(checker: fixture.checker)
        XCTAssertNil(state.updateInstallBlockedReason)

        state.pipeline.enqueueFiles([URL(fileURLWithPath: "/tmp/update-gate.wav")])
        XCTAssertEqual(state.updateInstallBlockedReason, "Not available while meetings are being processed.")
        state.installUpdate()

        XCTAssertEqual(fixture.installer.startInstallCalls, 0)
    }

    func testAnInstallRecordsWatchingAndTheNextLaunchTurnsItBackOn() async throws {
        let store = try makeStore()
        let running = try makeFixture(store: store)
        running.checker.availableBuildSummary = Self.summary
        let runningState = try makeAppState(checker: running.checker)
        addTeardownBlock { runningState.watching.watchLoop?.stop() }
        runningState.watching.toggleWatching(userInitiated: false)
        await waitFor(runningState.isWatching, timeout: .seconds(2))

        runningState.installUpdate()
        XCTAssertTrue(try XCTUnwrap(store.load()).wasWatching)

        // mt-update replaced and reopened the app: a new build, the same defaults.
        let reopened = try makeFixture(store: store)
        reopened.installer.build = Self.newBuild
        let reopenedState = try makeAppState(checker: reopened.checker)
        addTeardownBlock { reopenedState.watching.watchLoop?.stop() }
        reopenedState.resumeUpdateAfterLaunch()
        await waitFor(reopenedState.isWatching, timeout: .seconds(2))

        XCTAssertTrue(reopenedState.isWatching)
        XCTAssertEqual(reopened.notifier.calls.map(\.title), ["Update installed"])
    }

    // MARK: - Helpers

    private func makeFixture(
        store: PendingUpdateInstallStore? = nil,
        recheckInterval: Duration = .seconds(30),
    ) throws -> Fixture {
        let installer = MockMtUpdateInstaller()
        let notifier = RecordingNotifier()
        let provider = MockUpdateProvider()
        let store = try store ?? makeStore()
        let checker = UpdateChecker(
            provider: provider,
            installer: installer,
            notifier: notifier,
            pendingStore: store,
            recheckInterval: recheckInterval,
        )
        return Fixture(checker: checker, installer: installer, notifier: notifier, store: store, provider: provider)
    }

    private func makeStore() throws -> PendingUpdateInstallStore {
        let suite = "UpdateCheckerMtUpdateTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return try PendingUpdateInstallStore(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    private func pendingRecord(for installer: MockMtUpdateInstaller, wasWatching: Bool) -> PendingUpdateInstall {
        PendingUpdateInstall(
            startedAt: Date(timeIntervalSince1970: 3000),
            launch: installer.launch,
            previousBuild: installer.build,
            summary: Self.summary,
            wasWatching: wasWatching,
        )
    }

    /// An `AppState` over its own settings, folders and mock pipeline, with
    /// `checker` injected, so nothing reaches the installed app's state.
    private func makeAppState(checker: UpdateChecker) throws -> AppState {
        let directory = try makeTempDirectory(prefix: "UpdateCheckerMtUpdateTests")
        let suite = "UpdateCheckerMtUpdateTests-state-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = try AppSettings(
            defaults: XCTUnwrap(UserDefaults(suiteName: suite)),
            defaultOutputDir: directory.appendingPathComponent("output", isDirectory: true),
        )
        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: directory,
            logDir: directory,
        )
        return AppState(
            settings: settings,
            updateChecker: checker,
            pipelineEnvironment: IsolatedQueueEnvironment.make(logDir: directory, initialQueue: queue),
        )
    }
}
