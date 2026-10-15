import Foundation

/// An mt-update install this app started and has not reported yet. Written
/// right after the launch, because a successful install quits this process
/// and only the next launch can tell what happened.
struct PendingUpdateInstall: Codable, Equatable {
    let startedAt: Date
    let launch: MtUpdateLaunch
    /// The build that started the install; a different one at the next launch
    /// means the install went through.
    let previousBuild: BuildIdentity
    /// What was being installed, for the "Update installed" notice.
    let summary: String
    /// Whether meeting watching was on, so the new build can turn it back on.
    let wasWatching: Bool
}

/// Keeps the one pending-install record in the app's `UserDefaults`.
struct PendingUpdateInstallStore {
    static let key = "mtUpdatePendingInstall"

    let defaults: UserDefaults

    /// The record, or nil. A value that does not decode is removed, so a
    /// damaged record cannot make every launch report the same install.
    func load() -> PendingUpdateInstall? {
        guard let stored = defaults.object(forKey: Self.key) else { return nil }
        guard let data = stored as? Data,
              let record = try? JSONDecoder().decode(PendingUpdateInstall.self, from: data)
        else {
            clear()
            return nil
        }
        return record
    }

    func save(_ record: PendingUpdateInstall) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// How an mt-update install ended, as far as this app can tell.
enum UpdateInstallOutcome: Equatable {
    /// A new build runs; the summary is what the install was for.
    case installed(summary: String)
    /// mt-update exited 0 while this app still ran, so it did not restart it.
    case finishedWithoutRestart
    case mergeConflict
    case buildFailed
    /// mt-update gave up waiting for the app to become idle, or could not quit it.
    case busyOrNotQuittable
    case failed(MtUpdateExit)
    /// The child could not be launched; the reason is the launch error's.
    case notStartable(String)
    /// The same build runs and mt-update is gone.
    case didNotFinish

    /// The outcome of an mt-update that ended while this app still ran, from
    /// mt-update's exit codes: 2 merge conflict, 3 build failed, 4 busy too
    /// long or not quittable.
    static func forLiveExit(_ exit: MtUpdateExit) -> Self {
        switch exit {
        case .exited(0): .finishedWithoutRestart
        case .exited(2): .mergeConflict
        case .exited(3): .buildFailed
        case .exited(4): .busyOrNotQuittable
        case .exited, .signaled: .failed(exit)
        }
    }
}

/// What a launch makes of a pending-install record.
enum UpdateLaunchEvaluation: Equatable {
    case nothingPending
    case stillRunning(PendingUpdateInstall)
    case report(UpdateInstallOutcome, restoreWatching: Bool)

    /// A different build means installed, decided before liveness so a
    /// still-exiting mt-update never delays the success report. The same
    /// build is still being installed while the recorded mt-update runs, and
    /// did not finish once it is gone.
    static func evaluate(
        pending: PendingUpdateInstall?,
        currentBuild: BuildIdentity,
        isRunning: (MtUpdateLaunch) -> Bool,
    ) -> Self {
        guard let pending else { return .nothingPending }
        if currentBuild != pending.previousBuild {
            return .report(.installed(summary: pending.summary), restoreWatching: pending.wasWatching)
        }
        if isRunning(pending.launch) {
            return .stillRunning(pending)
        }
        return .report(.didNotFinish, restoreWatching: false)
    }
}

/// The notification for an install outcome. Pure text, in the manner of
/// `PreviousExitNotice`; it carries no date or time, so it does not depend on
/// the locale.
struct UpdateInstallNotice: Equatable {
    let title: String
    let body: String

    init(outcome: UpdateInstallOutcome, logPath: String) {
        let unchanged = "The installed app is unchanged. Details: \(logPath)"
        switch outcome {
        case let .installed(summary):
            title = "Update installed"
            body = "Now running the new build: \(summary)."

        case .finishedWithoutRestart:
            title = "Update installed"
            body = "mt-update finished without restarting the app. Quit and reopen Meeting Transcriber to use the new build."

        case .mergeConflict:
            title = "Update not installed"
            body = "mt-update hit a merge conflict. \(unchanged)"

        case .buildFailed:
            title = "Update not installed"
            body = "mt-update could not build the new version. \(unchanged)"

        case .busyOrNotQuittable:
            title = "Update not installed"
            body = "mt-update gave up: the app stayed busy too long or could not be quit. \(unchanged)"

        case let .failed(.exited(code)):
            title = "Update not installed"
            body = "mt-update failed with exit code \(code). \(unchanged)"

        case let .failed(.signaled(signal)):
            title = "Update not installed"
            body = "mt-update was ended by signal \(signal). \(unchanged)"

        case let .notStartable(reason):
            title = "Update not installed"
            body = "mt-update could not be started (\(reason)). The installed app is unchanged."

        case .didNotFinish:
            title = "Update did not finish"
            body = "mt-update ended without installing a new build, so this is still the previous build. Details: \(logPath)"
        }
    }
}

/// Why an install cannot start right now, mirroring what mt-update itself
/// waits for. Open speaker namings are not an input: they do not block an
/// install, as in mt-update, and reappear after the restart.
enum UpdateInstallGate {
    static func blockedReason(isRecording: Bool, manualRecordingStarting: Bool, waitingJobs: Int, activeJobs: Int) -> String? {
        if isRecording || manualRecordingStarting {
            return "Not available while recording."
        }
        if waitingJobs > 0 || activeJobs > 0 {
            return "Not available while meetings are being processed."
        }
        return nil
    }
}
