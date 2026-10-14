import Foundation

/// Whether an mt-update install this app knows of is running.
enum UpdateInstallState: Equatable {
    case idle
    /// mt-update runs; the date is when the install started.
    case installing(since: Date)
}

/// mt-update mode: checks and installs go through `installer` instead of the
/// GitHub release provider. Chosen once at launch (`AppState`); `checkNow`
/// delegates here at its top, so GitHub mode keeps its own path unchanged.
extension UpdateChecker {
    var isMtUpdateMode: Bool {
        installer != nil
    }

    var isInstalling: Bool {
        if case .installing = installState { return true }
        return false
    }

    /// A newer GitHub release or a newer mt-update build: what the menu-bar
    /// badge and `/state.updateStatus` report, in either mode.
    var hasAvailableUpdate: Bool {
        availableUpdate != nil || availableBuildSummary != nil
    }

    // MARK: - Check

    /// Runs `mt-update --check --porcelain`; "Include Pre-Releases" means
    /// nothing to it. Refused while a check or an install runs, because both
    /// work on mt-update's git checkout. A failed check keeps a build found
    /// earlier on offer.
    func checkWithMtUpdate(_ installer: any MtUpdateInstalling) {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        lastError = nil
        lastInstallError = nil

        Task {
            let outcome = await installer.check()
            switch outcome {
            case .upToDate:
                availableBuildSummary = nil
                lastCheckDate = Date()

            case let .updateAvailable(summary):
                availableBuildSummary = summary
                lastCheckDate = Date()

            case let .failed(failure):
                lastError = failure.message(checkLogPath: installer.checkLogPath)
            }
            isChecking = false
        }
    }

    // MARK: - Install

    /// Starts mt-update's install in the background. Does nothing outside
    /// mt-update mode, without an available build, while an install or a
    /// check runs, or while `blockedReason` (`UpdateInstallGate`) says why
    /// not. `isWatching` goes into the pending record, so the build that
    /// replaces this one can turn meeting watching back on.
    ///
    /// The record is saved before any exit is handled, even for a child that
    /// exits at once: this runs on the main actor, and `onExit` hops back to it.
    func installNow(blockedReason: String?, isWatching: Bool) {
        guard let installer, let summary = availableBuildSummary,
              !isInstalling, !isChecking, blockedReason == nil
        else { return }

        let startedAt = Date()
        let launch: MtUpdateLaunch
        do {
            launch = try installer.startInstall { [weak self] exit in
                Task { @MainActor [weak self] in
                    self?.finishInstall(.forLiveExit(exit), installing: summary)
                }
            }
        } catch {
            lastInstallError = post(.notStartable(error.localizedDescription), logPath: installer.installLogPath).body
            return
        }
        pendingStore.save(PendingUpdateInstall(
            startedAt: startedAt,
            launch: launch,
            previousBuild: installer.currentBuild(),
            summary: summary,
            wasWatching: isWatching,
        ))
        installState = .installing(since: startedAt)
        lastInstallError = nil
    }

    // MARK: - Launch

    /// Reports the install a previous instance started, once per instance and
    /// only in mt-update mode (`UpdateLaunchEvaluation`). While mt-update
    /// still runs, the install shows as running and is looked at again every
    /// `recheckInterval` until it has gone: this instance never gets that
    /// child's exit, so nothing else would return it to idle.
    ///
    /// - Returns: whether meeting watching was on when a now installed build
    ///   was started, so the caller turns it back on.
    func resumeAfterLaunch() -> Bool {
        guard let installer, !hasResumedAfterLaunch else { return false }
        hasResumedAfterLaunch = true
        let pending = pendingStore.load()
        switch evaluate(pending, installer: installer) {
        case .nothingPending:
            return false

        case let .stillRunning(pending):
            installState = .installing(since: pending.startedAt)
            recheckUntilFinished()
            return false

        case let .report(outcome, restoreWatching):
            finishInstall(outcome, installing: pending?.summary)
            return restoreWatching
        }
    }

    // MARK: - Private

    private func evaluate(_ pending: PendingUpdateInstall?, installer: any MtUpdateInstalling) -> UpdateLaunchEvaluation {
        UpdateLaunchEvaluation.evaluate(
            pending: pending,
            currentBuild: installer.currentBuild(),
        ) { installer.isRunning($0) }
    }

    private func recheckUntilFinished() {
        Task { [weak self] in
            while let interval = self?.recheckInterval {
                try? await Task.sleep(for: interval)
                guard let self, let installer else { return }
                let pending = pendingStore.load()
                switch evaluate(pending, installer: installer) {
                case .stillRunning:
                    continue

                case let .report(outcome, _):
                    finishInstall(outcome, installing: pending?.summary)
                    return

                case .nothingPending:
                    // The record is gone without a report (it no longer
                    // decoded): nothing is left to say, only to stop waiting.
                    installState = .idle
                    return
                }
            }
        }
    }

    /// The end of an install, for its live exit and for the launch-time
    /// report alike: posts its notice, clears the record and returns to idle.
    /// A failure stays on show in `lastInstallError`, and the build
    /// `installing` names stays on offer, so Install is available again. An
    /// instance that relaunched has no summary of its own until a check runs,
    /// which is why the caller passes the record's. A finished install
    /// clears it.
    private func finishInstall(_ outcome: UpdateInstallOutcome, installing summary: String?) {
        guard let installer else { return }
        let notice = post(outcome, logPath: installer.installLogPath)
        pendingStore.clear()
        installState = .idle
        switch outcome {
        case .installed, .finishedWithoutRestart:
            availableBuildSummary = nil

        case .mergeConflict, .buildFailed, .busyOrNotQuittable, .failed, .notStartable, .didNotFinish:
            lastInstallError = notice.body
            availableBuildSummary = summary ?? availableBuildSummary
        }
    }

    private func post(_ outcome: UpdateInstallOutcome, logPath: String) -> UpdateInstallNotice {
        let notice = UpdateInstallNotice(outcome: outcome, logPath: logPath)
        notifier.notify(title: notice.title, body: notice.body, urgency: .standard)
        return notice
    }
}
