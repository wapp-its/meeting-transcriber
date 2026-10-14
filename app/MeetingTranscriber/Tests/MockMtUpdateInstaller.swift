import Foundation
@testable import MeetingTranscriber

/// A scripted `MtUpdateInstalling` for `UpdateChecker` tests: no process
/// runs. A test sets the check's answer, makes the install launch throw,
/// fires the captured exit by hand, and sets the build this "process" runs as
/// and whether a recorded install still runs. `@unchecked Sendable` like
/// `MockUpdateProvider`: tests read it only after awaiting the checker.
final class MockMtUpdateInstaller: MtUpdateInstalling, @unchecked Sendable {
    struct LaunchFailed: LocalizedError {
        var errorDescription: String? {
            "launch refused"
        }
    }

    var checkOutcome: MtUpdateCheckOutcome = .upToDate
    /// How long a check takes, so a test can act while one is in flight.
    var checkDelay: Duration?
    /// When set, `startInstall` throws it instead of launching.
    var launchError: (any Error)?
    var build = BuildIdentity(gitCommitHash: "1a2b3c4", executableModified: Date(timeIntervalSince1970: 1000))
    var launch = MtUpdateLaunch(pid: 4242, processStart: Date(timeIntervalSince1970: 2000))
    var isInstallRunning = false

    private(set) var checkCalls = 0
    private(set) var startInstallCalls = 0
    private var onExit: (@Sendable (MtUpdateExit) -> Void)?

    let installLogPath = "/test/Logs/MeetingTranscriber/mt-update.log"
    let checkLogPath = "/test/Logs/MeetingTranscriber/mt-update-check.log"

    func currentBuild() -> BuildIdentity {
        build
    }

    func check() async -> MtUpdateCheckOutcome {
        checkCalls += 1
        if let checkDelay { try? await Task.sleep(for: checkDelay) }
        return checkOutcome
    }

    func startInstall(onExit: @escaping @Sendable (MtUpdateExit) -> Void) throws -> MtUpdateLaunch {
        startInstallCalls += 1
        if let launchError { throw launchError }
        self.onExit = onExit
        return launch
    }

    func isRunning(_: MtUpdateLaunch) -> Bool {
        isInstallRunning
    }

    /// Ends the launched install the way its termination handler would.
    func exit(_ exit: MtUpdateExit) {
        onExit?(exit)
    }
}
