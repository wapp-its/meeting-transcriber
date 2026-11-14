// Fork only: Launch at login is on by default in the fork's own builds.
//
// The original ships the Launch at login toggle off. A menu bar app that is
// not running looks exactly like one that is idle, so after a restart such a
// build watched nothing until someone noticed. Here the first launch from
// /Applications registers the login item, once. From then on the user's choice,
// made in Settings or in System Settings → Login Items, is never touched again:
// the step records that it had its chance in `appliedKey`, and every later
// launch only reports. In its own file so the nightly merge of the original
// meets no fork edit in the original's files.
import AppKit
import os.log
import ServiceManagement

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LoginItem")

enum LoginItemDefault {
    /// Set once the default had its one chance, whatever came of it; absent
    /// means not applied. Outside `AppSettings` because it records a step and
    /// is no setting. `UserDefaults` is per bundle identifier, so the Dev and
    /// the release-named build each keep their own, as they keep their own
    /// login item.
    static let appliedKey = "loginItemDefaultApplied"

    /// The only folder the default applies in. A build folder, the user's own
    /// Applications folder (where the e2e scripts deploy a copy with the same
    /// bundle identifier), a disk image or the temporary path macOS runs a
    /// freshly downloaded app from never become a login item by themselves.
    static let applicationsFolder = "/Applications"

    /// The names a Meeting Transcriber bundle is installed under there: the
    /// release-named build and mt-update's Dev build. With the other one
    /// installed as well, both would start at login and both would record the
    /// same meeting, so the choice is left to the user.
    static let installedNames = ["MeetingTranscriber.app", "MeetingTranscriber-Dev.app"]

    /// App Review Guideline 2.4.5 forbids starting at login without the
    /// user's consent, so the App Store build never applies the default and
    /// has no register call in it at all (`register(_:)`). The flag only picks
    /// the production value; `apply` takes it as a parameter, so the tests run
    /// both answers in either variant.
    #if APPSTORE
        static let isAppStoreBuild = true
    #else
        static let isAppStoreBuild = false
    #endif

    /// What one launch's step did, worded as the launch line names it.
    enum Outcome: String {
        case registered
        case alreadyOn = "already-on"
        case waitingApproval = "waiting-approval"
        case alreadyApplied = "already-applied"
        case failed
        case skippedAppStore = "skipped-appstore"
        case skippedLocation = "skipped-location"
        case skippedOtherCopy = "skipped-other-copy"

        /// Whether the step records the default as applied. The App Store and
        /// location skips do not, so the default still applies once the app
        /// runs from /Applications. A failed register does, so a refusal is
        /// not repeated at every launch.
        var marksApplied: Bool {
            switch self {
            case .registered, .alreadyOn, .waitingApproval, .failed, .skippedOtherCopy:
                true

            case .alreadyApplied, .skippedAppStore, .skippedLocation:
                false
            }
        }
    }

    private enum Decision {
        case register
        case leave(Outcome)
    }

    /// Run the step and log its line once AppKit has finished launching.
    /// Called from `AppLauncher.main()`, which xctest never enters, so no test
    /// reaches the real login item service. The notification is posted once
    /// per process, so the observer is never removed.
    @MainActor
    static func applyAfterLaunch() {
        // swiftlint:disable:next discarded_notification_center_observer
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main,
        ) { _ in
            MainActor.assumeIsolated {
                let service = SMAppService.mainApp
                let outcome = apply(registrar: service, defaults: .standard, bundleURL: Bundle.main.bundleURL)
                // Notice, not info: info lines are not kept, and this is the
                // line read after an install to see whether the item survived.
                logger.notice("\(launchLine(status: service.status, outcome: outcome), privacy: .public)")
            }
        }
    }

    /// The default's step for one launch: decide, register when the decision
    /// says so, and record that the default was applied when the outcome
    /// spends it.
    @MainActor
    static func apply(
        registrar: any LoginItemRegistering,
        defaults: UserDefaults,
        bundleURL: URL,
        isAppStore: Bool = isAppStoreBuild,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> Outcome {
        let bundle = bundleURL.resolvingSymlinksInPath()
        let decision = decide(
            isAppStore: isAppStore,
            bundle: bundle,
            otherCopyInstalled: otherCopyInstalled(bundle: bundle, fileExists: fileExists),
            alreadyApplied: defaults.bool(forKey: appliedKey),
            status: registrar.status,
        )
        let outcome = switch decision {
        case .register: register(registrar)
        case let .leave(outcome): outcome
        }
        if outcome.marksApplied {
            defaults.set(true, forKey: appliedKey)
        }
        return outcome
    }

    /// The launch line, content-free: the status macOS reports after the
    /// step and what the step did.
    static func launchLine(status: SMAppService.Status, outcome: Outcome) -> String {
        "login_item status=\(statusWord(status)) default=\(outcome.rawValue)"
    }

    /// Pure. The skips come before the status, so a build that may not apply
    /// the default never acts on what macOS reports.
    private static func decide(
        isAppStore: Bool, bundle: URL, otherCopyInstalled: Bool, alreadyApplied: Bool, status: SMAppService.Status,
    ) -> Decision {
        if isAppStore { return .leave(.skippedAppStore) }
        if alreadyApplied { return .leave(.alreadyApplied) }
        guard bundle.deletingLastPathComponent().path == applicationsFolder else {
            return .leave(.skippedLocation)
        }
        if otherCopyInstalled { return .leave(.skippedOtherCopy) }
        switch status {
        case .enabled:
            return .leave(.alreadyOn)

        // Registered already; a second register changes nothing until the
        // user approves it in System Settings.
        case .requiresApproval:
            return .leave(.waitingApproval)

        case .notRegistered, .notFound:
            return .register

        // A status this SDK does not know reads as off in the toggle
        // (`LoginItemState`), so the default treats it as off too.
        @unknown default:
            return .register
        }
    }

    /// Whether a Meeting Transcriber bundle other than the running one is in
    /// /Applications. The running bundle's own name is compared without case,
    /// as the file system does, so it never counts as the other copy.
    private static func otherCopyInstalled(bundle: URL, fileExists: (String) -> Bool) -> Bool {
        let ownName = bundle.lastPathComponent.lowercased()
        return installedNames.contains { name in
            name.lowercased() != ownName && fileExists("\(applicationsFolder)/\(name)")
        }
    }

    @MainActor
    private static func register(_ registrar: any LoginItemRegistering) -> Outcome {
        #if APPSTORE
            // `decide` skips every launch of this build before it gets here.
            // Left out all the same, so the build carries no path that adds a
            // login item without the user's click.
            return .skippedAppStore
        #else
            do {
                try registrar.register()
                return .registered
            } catch {
                return .failed
            }
        #endif
    }

    private static func statusWord(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notRegistered: "notRegistered"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}
