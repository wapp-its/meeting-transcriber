@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The About tab (Version, Identifier, Build Date, ffmpeg, GitHub link) plus
/// the Updates section moved into it from General. Split out of
/// `SettingsViewTests` when adding the identifier row took that file past the
/// 600-line cap; the section is self-contained, so it makes a natural seam.
@MainActor
final class AboutSettingsViewTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    /// Per-test isolated UserDefaults suite — same pattern as the sibling
    /// settings suites. Avoids `swift test --parallel` plist races and keeps a
    /// killed test process from leaking into the dev app's `.standard` plist.
    override func setUp() async throws {
        try await super.setUp()
        testSuiteName = "AboutSettingsViewTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() async throws {
        DefaultsSuite.remove(testSuiteName)
        defaults = nil
        testSuiteName = nil
        try await super.tearDown()
    }

    private func makeAbout(
        settings: AppSettings? = nil,
        updateChecker: UpdateChecker? = nil,
        updateInstallBlockedReason: String? = nil,
        onInstallUpdate: (() -> Void)? = nil,
    ) -> AboutSettingsView {
        AboutSettingsView(
            settings: settings ?? AppSettings(defaults: defaults),
            updateChecker: updateChecker,
            updateInstallBlockedReason: updateInstallBlockedReason,
            onInstallUpdate: onInstallUpdate,
        )
    }

    func testAboutSectionExists() throws {
        let body = try makeAbout().inspect()
        XCTAssertNoThrow(try body.find(text: "Version"))
    }

    func testAboutSectionShowsBuildDate() throws {
        let body = try makeAbout().inspect()
        XCTAssertNoThrow(try body.find(text: "Build Date"))
    }

    /// The identifier decides which settings domain, TCC grants and notification
    /// registration the running app uses, so "which build is this" is not
    /// answerable from the version alone — a dev/release mix-up otherwise shows
    /// up only as permissions or preferences inexplicably missing.
    func testAboutSectionShowsBundleIdentifier() throws {
        let body = try makeAbout().inspect()
        XCTAssertNoThrow(try body.find(text: "Identifier"))
    }

    func testAboutSectionShowsFfmpegStatus() throws {
        let body = try makeAbout().inspect()
        XCTAssertNoThrow(try body.find(text: "ffmpeg"))
    }

    func testAboutSectionShowsGitHubLink() throws {
        let body = try makeAbout().inspect()
        XCTAssertNoThrow(try body.find(text: "GitHub"))
    }

    func testUpdatesSectionShownWhenUpdateCheckerPresent() throws {
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let body = try makeAbout(updateChecker: checker).inspect()
        XCTAssertNoThrow(try body.find(text: "Check for Updates"))
    }

    func testCheckNowButtonStartsAnUpdateCheck() throws {
        let provider = MockUpdateProvider()
        provider.delay = .seconds(1)
        let checker = UpdateChecker(provider: provider)
        let view = makeAbout(updateChecker: checker)

        try view.inspect().find(button: "Check Now").tap()

        XCTAssertTrue(checker.isChecking)
    }

    func testUpdatesSectionHiddenWhenNoChecker() throws {
        let body = try makeAbout().inspect()
        XCTAssertThrowsError(try body.find(text: "Check for Updates"))
    }

    func testPreReleaseToggleShownWhenCheckEnabled() throws {
        let settings = AppSettings(defaults: defaults)
        settings.checkForUpdates = true
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let body = try makeAbout(settings: settings, updateChecker: checker).inspect()
        XCTAssertNoThrow(try body.find(text: "Include Pre-Releases"))
    }

    func testPreReleaseToggleHiddenWhenCheckDisabled() throws {
        let settings = AppSettings(defaults: defaults)
        settings.checkForUpdates = false
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let body = try makeAbout(settings: settings, updateChecker: checker).inspect()
        XCTAssertThrowsError(try body.find(text: "Include Pre-Releases"))
    }

    /// GitHub mode keeps its release line and Download button, and never
    /// grows the mt-update Install button.
    func testGitHubModeOffersTheReleaseDownloadAndNoInstall() throws {
        let checker = UpdateChecker(provider: MockUpdateProvider())
        checker.availableUpdate = try ReleaseInfo(
            tagName: "v1.0.0",
            name: "Release v1.0.0",
            prerelease: false,
            htmlURL: XCTUnwrap(URL(string: "https://github.com/pasrom/meeting-transcriber/releases/tag/v1.0.0")),
            dmgURL: nil,
        )
        let body = try makeAbout(updateChecker: checker, onInstallUpdate: Self.wiredInstall).inspect()

        XCTAssertNoThrow(try body.find(text: "Update available: v1.0.0"))
        XCTAssertNoThrow(try body.find(button: "Download v1.0.0"))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.updateInstallButton))
    }

    // MARK: - mt-update mode

    private static let summary = "upstream 1a2b3c4 · wapp/main 5d6e7f8"
    private static let installCaption = "Builds the new version (about 5–10 minutes), then restarts Meeting Transcriber."
    /// A wired install callback, for tests that only need the button enabled.
    private static let wiredInstall: () -> Void = {}

    /// A checker in mt-update mode offering `summary`. No process runs, and
    /// the pending record would land in this test's own defaults suite.
    private func makeMtUpdateChecker(summary: String? = summary) -> UpdateChecker {
        let checker = UpdateChecker(
            provider: MockUpdateProvider(),
            installer: MockMtUpdateInstaller(),
            pendingStore: PendingUpdateInstallStore(defaults: defaults),
        )
        checker.availableBuildSummary = summary
        return checker
    }

    private func installButton(in view: AboutSettingsView) throws -> InspectableView<ViewType.Button> {
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.updateInstallButton)
            .find(ViewType.Button.self)
    }

    /// The one wiring test: found by its identifier, tapped, the callback ran.
    func testInstallUpdateButtonCallsTheInstallCallback() throws {
        var installs = 0
        // swiftlint:disable:next trailing_closure
        let view = makeAbout(updateChecker: makeMtUpdateChecker(), onInstallUpdate: { installs += 1 })

        let button = try installButton(in: view)
        XCTAssertFalse(button.isDisabled())
        try button.tap()

        XCTAssertEqual(installs, 1)
        XCTAssertNoThrow(try view.inspect().find(text: Self.installCaption))
    }

    /// A blocking reason, a running check or a missing callback each disable
    /// the button; a reason replaces the caption, so About names it.
    func testInstallUpdateButtonIsDisabledWhileBlockedCheckingOrUnwired() throws {
        let reason = "Not available while recording."
        let rows: [(name: String, reason: String?, checking: Bool, callback: (() -> Void)?)] = [
            ("blocked", reason, false, Self.wiredInstall),
            ("checking", nil, true, Self.wiredInstall),
            ("no callback", nil, false, nil),
        ]
        for row in rows {
            let checker = makeMtUpdateChecker()
            checker.isChecking = row.checking
            let view = makeAbout(updateChecker: checker, updateInstallBlockedReason: row.reason, onInstallUpdate: row.callback)

            XCTAssertTrue(try installButton(in: view).isDisabled(), row.name)
            XCTAssertNoThrow(try view.inspect().find(text: row.reason ?? Self.installCaption), row.name)
        }
        let blocked = makeAbout(updateChecker: makeMtUpdateChecker(), updateInstallBlockedReason: reason, onInstallUpdate: Self.wiredInstall)
        XCTAssertThrowsError(try blocked.inspect().find(text: Self.installCaption))
    }

    /// mt-update builds whatever its branches hold, so the pre-release switch
    /// goes and a caption says where updates come from (A5).
    func testMtUpdateModeShowsItsCaptionInsteadOfPreReleases() throws {
        let settings = AppSettings(defaults: defaults)
        settings.checkForUpdates = true
        let body = try makeAbout(settings: settings, updateChecker: makeMtUpdateChecker()).inspect()

        XCTAssertNoThrow(try body.find(text: "Updates are built on this Mac by mt-update."))
        XCTAssertThrowsError(try body.find(text: "Include Pre-Releases"))
    }

    /// The status line as in GitHub mode, naming the build's summary; an
    /// mt-update that predates the contract says so and offers no install (R3).
    func testMtUpdateStatusLineAndWhenInstallIsOffered() throws {
        let unsupported = MtUpdateCheckFailure.unsupported.message(checkLogPath: MockMtUpdateInstaller().checkLogPath)
        let rows: [(summary: String?, error: String?, line: String, offersInstall: Bool)] = [
            (Self.summary, nil, "Update available: \(Self.summary)", true),
            (nil, nil, "Up to date", false),
            (nil, unsupported, unsupported, false),
        ]
        for row in rows {
            let checker = makeMtUpdateChecker(summary: row.summary)
            checker.lastCheckDate = Date()
            checker.lastError = row.error
            let body = try makeAbout(updateChecker: checker, onInstallUpdate: Self.wiredInstall).inspect()

            XCTAssertNoThrow(try body.find(text: row.line), row.line)
            let install = try? body.find(viewWithAccessibilityIdentifier: A11yID.updateInstallButton)
            XCTAssertEqual(install != nil, row.offersInstall, row.line)
        }
    }

    /// While mt-update runs, the progress text takes the button's place and
    /// "Check Now" is unavailable: no second install and no check (R4).
    func testWhileInstallingTheProgressTextReplacesTheButtonAndChecksAreOff() throws {
        let checker = makeMtUpdateChecker()
        checker.installState = .installing(since: Date())
        let body = try makeAbout(updateChecker: checker, onInstallUpdate: Self.wiredInstall).inspect()

        XCTAssertNoThrow(try body.find(
            text: "Installing update… Meeting Transcriber restarts when the build is done and nothing is recording or processing.",
        ))
        XCTAssertThrowsError(try body.find(viewWithAccessibilityIdentifier: A11yID.updateInstallButton))
        XCTAssertTrue(try body.find(button: "Check Now").isDisabled())
    }

    /// A failed install stays on show, and the build it tried is offered
    /// again (R6).
    func testTheLastInstallFailureIsShownWithInstallOfferedAgain() throws {
        let failure = UpdateInstallNotice(outcome: .buildFailed, logPath: MockMtUpdateInstaller().installLogPath).body
        let checker = makeMtUpdateChecker()
        checker.lastInstallError = failure
        let view = makeAbout(updateChecker: checker, onInstallUpdate: Self.wiredInstall)

        XCTAssertNoThrow(try view.inspect().find(text: failure))
        XCTAssertFalse(try installButton(in: view).isDisabled())
    }

    #if !APPSTORE
        /// A press on either Install control starts mt-update, which quits
        /// the app, so the automation API must never be able to press one.
        func testNeitherInstallControlIsPressableThroughTheAutomationAPI() {
            XCTAssertFalse(DebugRPCServer.isIdentifierAllowedForUIPress(A11yID.updateInstallButton))
            XCTAssertFalse(DebugRPCServer.isIdentifierAllowedForUIPress(A11yID.menuInstallUpdateButton))
        }
    #endif
}
