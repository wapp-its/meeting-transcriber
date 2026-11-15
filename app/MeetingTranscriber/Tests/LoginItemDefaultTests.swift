@testable import MeetingTranscriber
import ServiceManagement
import XCTest

/// Stands in for `SMAppService.mainApp`. Nothing here may reach the real
/// service: registering from a test run would add a real login item for
/// whatever binary hosts the tests.
@MainActor
private final class FakeRegistrar: LoginItemRegistering {
    struct Refused: Error {}

    var status: SMAppService.Status
    var refuses = false
    private(set) var registerCalls = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if refuses { throw Refused() }
        status = .enabled
    }

    func unregister() {
        status = .notRegistered
    }
}

/// The fork's default: Launch at login is applied once, at the first launch
/// from /Applications, and never again.
@MainActor
final class LoginItemDefaultTests: XCTestCase {
    private static let dev = "/Applications/MeetingTranscriber-Dev.app"
    private static let release = "/Applications/MeetingTranscriber.app"

    private func makeDefaults() throws -> UserDefaults {
        let name = "LoginItemDefaultTests-\(getpid())-\(UUID().uuidString)"
        let suite = try XCTUnwrap(DefaultsSuite.open(name))
        addTeardownBlock { DefaultsSuite.remove(name) }
        return suite
    }

    /// One launch of the bundle at `path`. On disk are that bundle and the
    /// ones in `alsoInstalled`, nothing else.
    private func launch(
        _ registrar: FakeRegistrar, _ defaults: UserDefaults,
        from path: String = LoginItemDefaultTests.dev, alsoInstalled: Set<String> = [], isAppStore: Bool = false,
    ) -> LoginItemDefault.Outcome {
        LoginItemDefault.apply(
            registrar: registrar, defaults: defaults, bundleURL: URL(fileURLWithPath: path), isAppStore: isAppStore,
        ) { $0 == path || alsoInstalled.contains($0) }
    }

    private func isApplied(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: LoginItemDefault.appliedKey)
    }

    private func isUnset(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: LoginItemDefault.appliedKey) == nil
    }

    // MARK: - R2: once, at the first launch from /Applications

    #if !APPSTORE
        /// Two launches in a row register once. The running bundle is on disk
        /// in /Applications, under either name, and never counts as the other
        /// copy.
        func testTheFirstLaunchRegistersAndTheNextDoesNot() throws {
            for path in [Self.dev, Self.release] {
                for status in [SMAppService.Status.notRegistered, .notFound] {
                    let fake = FakeRegistrar(status: status)
                    let defaults = try makeDefaults()
                    let label = "\(path) \(status.rawValue)"

                    XCTAssertEqual(launch(fake, defaults, from: path), .registered, label)
                    XCTAssertTrue(isApplied(defaults), label)
                    XCTAssertEqual(launch(fake, defaults, from: path), .alreadyApplied, label)
                    XCTAssertEqual(fake.registerCalls, 1, label)
                }
            }
        }

        /// Switched off after the default applied, in Settings or in System
        /// Settings: macOS reports it unregistered, and it stays that way.
        func testAUserWhoSwitchedItOffStaysOff() throws {
            let fake = FakeRegistrar(status: .notRegistered)
            let defaults = try makeDefaults()
            _ = launch(fake, defaults)
            fake.status = .notRegistered

            XCTAssertEqual(launch(fake, defaults), .alreadyApplied)
            XCTAssertEqual(fake.registerCalls, 1)
            XCTAssertEqual(fake.status, .notRegistered)
        }

        /// A refused register is logged as failed and spends the default, so it
        /// is not tried again at every launch; the toggle then shows off,
        /// because it shows what macOS reports.
        func testARefusedRegisterIsNotRetriedAndTheToggleShowsOff() throws {
            let fake = FakeRegistrar(status: .notRegistered)
            fake.refuses = true
            let defaults = try makeDefaults()

            let outcome = launch(fake, defaults)

            XCTAssertEqual(outcome, .failed)
            XCTAssertEqual(
                LoginItemDefault.launchLine(status: fake.status, outcome: outcome),
                "login_item status=notRegistered default=failed",
            )
            XCTAssertTrue(isApplied(defaults))
            XCTAssertEqual(launch(fake, defaults), .alreadyApplied)
            XCTAssertEqual(fake.registerCalls, 1)
            let toggle = LoginItemController(registrar: fake)
            toggle.refresh()
            XCTAssertFalse(toggle.isOn)
        }
    #endif

    /// Already on, or registered and waiting for the user's approval: nothing
    /// to register, and the default is spent.
    func testAnItemAlreadyThereIsLeftAndSpendsTheDefault() throws {
        let cases: [(status: SMAppService.Status, outcome: LoginItemDefault.Outcome)] = [
            (.enabled, .alreadyOn),
            (.requiresApproval, .waitingApproval),
        ]
        for testCase in cases {
            let fake = FakeRegistrar(status: testCase.status)
            let defaults = try makeDefaults()

            XCTAssertEqual(launch(fake, defaults), testCase.outcome)
            XCTAssertEqual(fake.registerCalls, 0)
            XCTAssertTrue(isApplied(defaults))
        }
    }

    // MARK: - R3: never registered by the default

    /// The App Store build never applies it and leaves the key unset. In that
    /// build the register call is compiled out as well, so not even a wrong
    /// verdict could add the item.
    func testTheAppStoreBuildNeverRegisters() throws {
        let fake = FakeRegistrar(status: .notRegistered)
        let defaults = try makeDefaults()

        XCTAssertEqual(launch(fake, defaults, isAppStore: true), .skippedAppStore)
        #if APPSTORE
            XCTAssertEqual(launch(fake, defaults, isAppStore: false), .skippedAppStore)
        #endif
        XCTAssertEqual(fake.registerCalls, 0)
        XCTAssertTrue(isUnset(defaults))
    }

    /// A bundle not directly in /Applications is skipped without spending the
    /// default, so the same build applies it once it runs from there.
    func testABundleOutsideApplicationsIsSkippedAndKeepsTheDefault() throws {
        let paths = [
            "/Users/someone/Applications/MeetingTranscriber-Dev.app",
            "/Users/someone/src/meeting-transcriber/app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app",
            "/Volumes/Meeting Transcriber/MeetingTranscriber.app",
            "/private/var/folders/xy/abc/T/AppTranslocation/0A1B/d/MeetingTranscriber.app",
            "/Applications/Utilities/MeetingTranscriber-Dev.app",
        ]
        for path in paths {
            let fake = FakeRegistrar(status: .notRegistered)
            let defaults = try makeDefaults()

            XCTAssertEqual(launch(fake, defaults, from: path), .skippedLocation, path)
            XCTAssertEqual(fake.registerCalls, 0, path)
            XCTAssertTrue(isUnset(defaults), path)
            #if !APPSTORE
                XCTAssertEqual(launch(fake, defaults), .registered, "then from /Applications: \(path)")
            #endif
        }
    }

    /// With the other Meeting Transcriber copy in /Applications the default
    /// registers nothing and is spent: the user picks in Settings.
    func testAnotherCopyInApplicationsSpendsTheDefaultWithoutRegistering() throws {
        for (running, other) in [(Self.dev, Self.release), (Self.release, Self.dev)] {
            let fake = FakeRegistrar(status: .notRegistered)
            let defaults = try makeDefaults()

            XCTAssertEqual(launch(fake, defaults, from: running, alsoInstalled: [other]), .skippedOtherCopy, running)
            XCTAssertEqual(fake.registerCalls, 0, running)
            XCTAssertTrue(isApplied(defaults), running)
        }
    }

    // MARK: - R4: the launch line

    func testTheLaunchLineNamesTheStatusAndWhatTheStepDid() {
        let cases: [(status: SMAppService.Status, outcome: LoginItemDefault.Outcome, line: String)] = [
            (.enabled, .registered, "login_item status=enabled default=registered"),
            (.enabled, .alreadyOn, "login_item status=enabled default=already-on"),
            (.requiresApproval, .waitingApproval, "login_item status=requiresApproval default=waiting-approval"),
            (.enabled, .alreadyApplied, "login_item status=enabled default=already-applied"),
            (.notRegistered, .failed, "login_item status=notRegistered default=failed"),
            (.notRegistered, .skippedAppStore, "login_item status=notRegistered default=skipped-appstore"),
            (.notFound, .skippedLocation, "login_item status=notFound default=skipped-location"),
            (.notRegistered, .skippedOtherCopy, "login_item status=notRegistered default=skipped-other-copy"),
        ]
        for testCase in cases {
            XCTAssertEqual(LoginItemDefault.launchLine(status: testCase.status, outcome: testCase.outcome), testCase.line)
        }
    }
}
