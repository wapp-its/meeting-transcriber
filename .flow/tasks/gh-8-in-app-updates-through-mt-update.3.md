---
satisfies: [R1, R2, R4, R5, R6, R7]
---
# gh-8-in-app-updates-through-mt-update.3 UpdateChecker mt-update mode and app wiring

## Description
Puts mt-update mode into `UpdateChecker` and wires it into the app: the check branch, starting an install, handling its exit while the app runs, the launch-time report with the 30 s recheck, mode selection at launch, the install gate on `AppState`, restoring meeting watching, and the badge and `/state.updateStatus` reading `hasAvailableUpdate`. No view changes here (task 4), so this task is fully testable through `UpdateChecker` with a mock installer.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/UpdateChecker.swift`, `app/MeetingTranscriber/Sources/UpdateChecker+MtUpdate.swift`, `app/MeetingTranscriber/Sources/AppState.swift`, `app/MeetingTranscriber/Sources/AppState+RPC.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Tests/MockMtUpdateInstaller.swift`, `app/MeetingTranscriber/Tests/UpdateCheckerMtUpdateTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/UpdateChecker.swift, app/MeetingTranscriber/Sources/UpdateChecker+MtUpdate.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/AppState+RPC.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Tests/MockMtUpdateInstaller.swift, app/MeetingTranscriber/Tests/UpdateCheckerMtUpdateTests.swift, app/MeetingTranscriber/Tests/RPCUpdateStatusTests.swift]

### Approach
- `UpdateChecker` (`UpdateChecker.swift:108-179`): new init parameters, all defaulted so every existing `UpdateChecker(provider:)` call stays valid: `installer: (any MtUpdateInstalling)? = nil`, `notifier: any AppNotifying = SilentNotifier()`, `pendingStore: PendingUpdateInstallStore = .init(defaults: .standard)`, `recheckInterval: Duration = .seconds(30)`. New observable state: `availableBuildSummary: String?`, `installState` (idle / installing since a date), `lastInstallError: String?`; computed `isMtUpdateMode`, `isInstalling`, `hasAvailableUpdate` (`availableUpdate != nil || availableBuildSummary != nil`). Stored properties stay in the class; the mt-update logic goes into the new extension file (600-line file cap).
- `checkNow`: in mt-update mode delegate at its top to a separate method in the extension (no interleaved branches in the existing body), which ignores `includePreReleases`, refuse while installing or already checking, then map `installer.check()`: up to date → clear the summary and set `lastCheckDate`; available → set the summary and `lastCheckDate`; failed → `lastError = failure.message(checkLogPath:)` and leave the summary as it was. GitHub mode unchanged. `startPeriodicChecks` needs no change.
- `installNow(blockedReason: String?, isWatching: Bool)`: no-op unless mt-update mode, a summary is available, not installing, not checking, and `blockedReason == nil`. Calls `installer.startInstall(onExit:)` with a callback that hops to the main actor (`Task { @MainActor [weak self] in … }`), then saves the `PendingUpdateInstall` (start time, launch, `installer.currentBuild()`, summary, `isWatching`) and sets installing. A throw posts the `.notStartable` notice and sets `lastInstallError`; nothing is saved.
- Live exit: `UpdateInstallOutcome.forLiveExit`, post `UpdateInstallNotice(outcome:logPath: installer.installLogPath)` with `.standard` urgency, clear the record, back to idle; on a failure set `lastInstallError` to the notice body and keep the summary (Install is offered again, R6); on `finishedWithoutRestart` clear the summary.
- `resumeAfterLaunch() -> Bool` (returns whether watching should be restored): only in mt-update mode and only once per instance. `UpdateLaunchEvaluation.evaluate(pending: pendingStore.load(), currentBuild: installer.currentBuild(), isRunning: installer.isRunning)`: report → post the notice, clear the record, return `restoreWatching`; still running → installing since the record's start, and a task that sleeps `recheckInterval` and re-evaluates until it is no longer running; that terminal evaluation posts its notice, clears the record and sets the install state back to idle (this instance never gets the child's termination callback, so nothing else would), after which checks and Install work again; nothing pending → false. One shared "finish" path for the live exit and the recheck keeps the idle reset in one place.
- `AppState` (`AppState.swift:207-236`): `makeUpdateChecker()` becomes `makeUpdateChecker(notifier:)` with an explicit return type (keep `init` under the type-check budget, see the comment at the top of `init`); under `#if !APPSTORE`, `MtUpdateProvider.detect()` non-nil → `UpdateChecker(installer:notifier:pendingStore:)`, else today's `UpdateChecker()`. Add `var updateInstallBlockedReason: String?` (`UpdateInstallGate.blockedReason(isRecording: watching.isRecording, manualRecordingStarting: watching.isManualRecording, waitingJobs: pipeline.queue.pendingJobs.count, activeJobs: pipeline.queue.activeJobs.count)`), `func installUpdate()` (→ `updateChecker.installNow(blockedReason:isWatching:)`) and `func resumeUpdateAfterLaunch()` (when `resumeAfterLaunch()` returns true and not already watching → `watching.toggleWatching(userInitiated: false)`, the auto-watch path). `currentBadge` (`:476`) reads `updateChecker.hasAvailableUpdate`.
- `AppState+RPC.swift:234-243`: `available: updateChecker.hasAvailableUpdate`, `availableVersion: update?.tagName ?? updateChecker.availableBuildSummary`.
- `MeetingTranscriberApp.swift:195-197`: the existing `.task` calls `appState.resumeUpdateAfterLaunch()` before `startPeriodicChecks`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/UpdateChecker.swift:106-179` — the class to extend
- `app/MeetingTranscriber/Sources/AppState.swift:195-260` — factories and init budget
- `app/MeetingTranscriber/Sources/WatchingController.swift:170-215` — `isWatching`, `isRecording`, the wide `isManualRecording`, `toggleWatching`
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:178-197` — auto-watch observer and the update `.task`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/UpdateCheckerTests.swift:1-30,250-310` — mock provider, `yieldUntil`, defaults suite
- `app/MeetingTranscriber/Tests/RecordingNotifier.swift` — notification spy
- `app/MeetingTranscriber/Tests/RPCUpdateStatusTests.swift` — `/state.updateStatus` wiring test to extend

### Key context
- Ordering is safe by construction: `installNow` runs on the main actor and the exit callback hops back to it, so the record is saved before any exit is handled, even for a child that exits at once.
- The auto-watch start posted 3 s after launch and the restore here both check "not already watching", so whichever runs second does nothing.
- `MockMtUpdateInstaller` (own test file, `@unchecked Sendable` like `MockUpdateProvider`): scripted check outcome, a throw switch for `startInstall`, the captured `onExit` to fire by hand, a settable build identity and running flag, call counters.
- Tests (`UpdateCheckerMtUpdateTests`, `@MainActor`, a `DefaultsSuite` store, `RecordingNotifier`): check mapping for each outcome, a failed check keeping an earlier summary; `checkNow` refused while installing; each `installNow` guard; the saved record's fields; exits 2, 3, 4, 9, a signal and 0 (notice title, log path in the body, record cleared, idle, error and summary as above); a throwing launch; `resumeAfterLaunch` for a new build (one "Update installed", returns `wasWatching`, record cleared, a second call posts nothing), same build gone ("Update did not finish"), same build running then gone after a 50 ms recheck interval (one notice, `isInstalling == false` afterwards, and a following `checkNow` reaches the installer), nothing pending; one `/state.updateStatus` test where only `availableBuildSummary` is set. Existing GitHub-mode tests stay unchanged.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh-8-test-home swift test --parallel --filter 'UpdateChecker|RPCUpdateStatus|RPCBadgeState|AppStateTests' > /private/tmp/gh-8-t3.log 2>&1` (read the log).
- `cd app/MeetingTranscriber && swift build --build-tests -Xswiftc -DAPPSTORE > /private/tmp/gh-8-t3-appstore.log 2>&1`.
- `./scripts/pre-push.sh` (release build; also the 300 ms type-check limit on `AppState.init` and the scene bodies).
- `./scripts/lint.sh` with the pinned tools.
## Acceptance
- [ ] In mt-update mode `checkNow` maps up to date, available and every failure as specified; a failed check keeps an earlier summary; a check is refused while installing; GitHub mode and all existing `UpdateChecker` tests are unchanged.
- [ ] `installNow` refuses without a summary, while installing, while checking and with a blocked reason; otherwise it starts the installer, saves the pending record (start, launch, current build, summary, watching flag) and reports installing.
- [ ] Each live exit posts exactly one notice through the notifier, clears the record and returns to idle; failures set `lastInstallError` and keep the summary; exit 0 clears the summary; a launch that throws posts the not-startable notice and saves nothing.
- [ ] `resumeAfterLaunch` posts one "Update installed" for a changed build and returns the recorded watching flag, posts one "Update did not finish" for the same build once the process is gone (immediately, or after the injected recheck interval when it was still running, after which the state is idle again and a new check reaches the installer), posts nothing with no record, and posts nothing on a second call.
- [ ] `AppState` picks mt-update mode only through `MtUpdateProvider.detect()` (non-App-Store), exposes the install reason from the gate, restores watching through the auto-watch path, and the badge and `/state.updateStatus` report an mt-update build (one RPC test).
- [ ] `./scripts/pre-push.sh` and the App Store test build succeed; lint clean.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
