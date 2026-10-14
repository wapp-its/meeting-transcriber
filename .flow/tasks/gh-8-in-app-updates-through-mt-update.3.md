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
- `UpdateChecker` (`UpdateChecker.swift:108-202`): new init parameters, all defaulted so every existing `UpdateChecker(provider:)` call stays valid: `installer: (any MtUpdateInstalling)? = nil`, `notifier: any AppNotifying = SilentNotifier()`, `pendingStore: PendingUpdateInstallStore = .init(defaults: .standard)`, `recheckInterval: Duration = .seconds(30)`. New observable state: `availableBuildSummary: String?`, `installState` (idle / installing since a date), `lastInstallError: String?`; computed `isMtUpdateMode`, `isInstalling`, `hasAvailableUpdate` (`availableUpdate != nil || availableBuildSummary != nil`). Stored properties stay in the class; the mt-update logic goes into the new extension file (600-line file cap).
- `checkNow`: in mt-update mode delegate at its top to a separate method in the extension (no interleaved branches in the existing body), which ignores `includePreReleases`, refuse while installing or already checking, then map `installer.check()`: up to date → clear the summary and set `lastCheckDate`; available → set the summary and `lastCheckDate`; failed → `lastError = failure.message(checkLogPath:)` and leave the summary as it was. GitHub mode unchanged. `startPeriodicChecks` needs no change.
- `installNow(blockedReason: String?, isWatching: Bool)`: no-op unless mt-update mode, a summary is available, not installing, not checking, and `blockedReason == nil`. Calls `installer.startInstall(onExit:)` with a callback that hops to the main actor (`Task { @MainActor [weak self] in … }`), then saves the `PendingUpdateInstall` (start time, launch, `installer.currentBuild()`, summary, `isWatching`) and sets installing. A throw posts the `.notStartable` notice and sets `lastInstallError`; nothing is saved.
- Live exit: `UpdateInstallOutcome.forLiveExit`, post `UpdateInstallNotice(outcome:logPath: installer.installLogPath)` with `.standard` urgency, clear the record, back to idle; on a failure set `lastInstallError` to the notice body and keep the summary (Install is offered again, R6); on `finishedWithoutRestart` clear the summary.
- `resumeAfterLaunch() -> Bool` (returns whether watching should be restored): only in mt-update mode and only once per instance. `UpdateLaunchEvaluation.evaluate(pending: pendingStore.load(), currentBuild: installer.currentBuild(), isRunning: installer.isRunning)`: report → post the notice, clear the record, return `restoreWatching`; still running → installing since the record's start, and a task that sleeps `recheckInterval` and re-evaluates until it is no longer running; that terminal evaluation posts its notice, clears the record and sets the install state back to idle (this instance never gets the child's termination callback, so nothing else would), after which checks and Install work again; nothing pending → false. One shared "finish" path for the live exit and the recheck keeps the idle reset in one place.
- `AppState` (`AppState.swift:117-135`): `makeUpdateChecker()` becomes `makeUpdateChecker(notifier:)` with an explicit return type (keep `init` under the type-check budget, see the comment at the top of `init`); under `#if !APPSTORE`, `MtUpdateProvider.detect()` non-nil → `UpdateChecker(installer:notifier:pendingStore:)`, else today's `UpdateChecker()`. Add `var updateInstallBlockedReason: String?` (`UpdateInstallGate.blockedReason(isRecording: watching.isRecording, manualRecordingStarting: watching.isManualRecording, waitingJobs: pipeline.queue.pendingJobs.count, activeJobs: pipeline.queue.activeJobs.count)`), `func installUpdate()` (→ `updateChecker.installNow(blockedReason:isWatching:)`) and `func resumeUpdateAfterLaunch()` (when `resumeAfterLaunch()` returns true and not already watching → `watching.toggleWatching(userInitiated: false)`, the auto-watch path). `currentBadge` (`:385`) reads `updateChecker.hasAvailableUpdate`.
- `AppState+RPC.swift:243-252`: `available: updateChecker.hasAvailableUpdate`, `availableVersion: update?.tagName ?? updateChecker.availableBuildSummary`.
- `MeetingTranscriberApp.swift:229-231`: the existing `.task` calls `appState.resumeUpdateAfterLaunch()` before `startPeriodicChecks`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/UpdateChecker.swift:106-202` — the class to extend
- `app/MeetingTranscriber/Sources/AppState.swift:100-160` — factories and init budget
- `app/MeetingTranscriber/Sources/WatchingController.swift:177-223` — `isWatching`, `isRecording`, the wide `isManualRecording`, `toggleWatching`
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:212-231` — auto-watch observer and the update `.task`

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
The installed Dev build with mt-update present now checks for updates through `mt-update --check --porcelain`, can start an install in the background, and reports how the install ended. The report arrives as a notification while the app runs, or at the next launch after mt-update replaced the app. `UpdateChecker` gained mt-update mode in `UpdateChecker+MtUpdate.swift`. `AppState` picks the mode through `MtUpdateProvider.detect()` outside the App Store build, exposes the install gate, and turns watching back on through the auto-watch path. The badge and `/state.updateStatus` report an mt-update build. No view changed (task 4 adds the About and menu controls).

stage: impl-review - ran [2026-10-14T12:15:22Z..2026-10-14T12:26:13Z]

Tier: implementer - opus at xhigh (explicit invocation) (model: claude-opus-5-5)

Review: codex:gpt-6-astra:xhigh, receipt effort xhigh, receipt /tmp/impl-review-receipt-cfaadf991a4c-gh-8-in-app-updates-through-mt-update.3.json, terminal verdict SHIP.
- Round 1 used three lenses. Correctness and integration returned NEEDS_WORK with the same P2 finding: after a relaunch, "Update did not finish" cleared the record without its summary, so Install stayed refused until a check ran (R7). Contracts returned SHIP. The round was finalized with `--merged-file`, because the contracts draw had no findings container and `--merge-plan` refused it.
- Fix 832d711f puts the record's summary back on offer for a failed or unfinished install. Both recovery tests failed for that reason before the fix (summary nil, 0 launches).
- Round 2 used one reviewer, which returned SHIP ("Prior finding #1: fixed"). No finding was declined.
- Commit 86901b1f landed after the SHIP and was not reviewed again. It adds one assertion to an existing test and changes no production code (Choices 3).
- The reviewer sandbox was workspace-write. After each round `git status` showed only flowctl's ledger (`.flow/specs/gh-8-in-app-updates-through-mt-update.json`, `.flow/review-runs/`), so nothing needed reverting.
- Memory captured: `bug/runtime-errors/relaunch-after-an-unfinished-install-2026-10-14`.

Verification
- baseline: green before any edit. `--filter 'MtUpdate|UpdateInstall|UpdateChecker|AboutSettingsView|MenuBarView|RPCUpdateStatus|RPCBadgeState|AppStateTests'` ran 195 tests, rc 0. Lint found 0 violations in 809 files.
- mutation check: nine deliberate defects each turned their target test red, and the sources were restored afterwards (cmp against backups). The defects were a failed check dropping the earlier build, `installNow` ignoring a running check, `resumeAfterLaunch` running twice, the recheck stopping after one look, the record always saying watching was on, AppState forwarding no blocked reason, `/state` dropping the summary, the finish path not returning to idle, and the next launch not turning watching on.
- the same filter on 832d711f ran 208 tests, rc 0. `--filter UpdateCheckerMtUpdateTests` on 86901b1f ran 12 tests, rc 0.
- `swift build --build-tests -Xswiftc -DAPPSTORE`: rc 0.
- `./scripts/pre-push.sh`: rc 0, "OK — pre-push parity check passed" (release build and the 300 ms type-check limit).
- `./scripts/lint.sh` with the cached pinned tools: 0 files need formatting, 0 violations in 812 files.
- not run: the app as a user meets it. mt-update mode is active only in `/Applications/MeetingTranscriber-Dev.app`, which only mt-update installs. This branch is not in `branches.txt`, and the fork rules forbid quitting the installed app any other way. The real install is the owner's check (spec Verification). Until task 4 nothing in the UI calls `installUpdate()`.
- not run: CI's `swiftlint analyze` (`unused_declaration`) needs a clean xcodebuild. `isMtUpdateMode` and `AppState.installUpdate()` have no production caller until task 4, and `lastInstallError` has no production reader until then, so that check may report them on this commit. `MtUpdateProvider.detect()` now has its production caller.

Error-case tests (R-IDs this task satisfies)
- R1, the App Store build has no code that starts mt-update: the factory branch is `#if !APPSTORE` and the App Store build succeeded. A path that cannot be read counts as absent: task 2's `testDetectNeedsAnExecutableMtUpdateAndTheInstalledBundle`.
- R2, other exit codes, a missing or contradicting status, a timeout or no launch give a failed-check message and never an update, and an earlier update stays shown: `UpdateCheckerMtUpdateTests.testACheckMapsEachOutcomeAndAFailureKeepsAnEarlierBuild`.
- R4, mt-update cannot be started: `testALaunchThatThrowsPostsNotStartableAndSavesNothing`. The guards (no build, installing, checking, blocked): `testInstallNowRefusesWithoutABuildWhileBusyAndWhenBlocked`, `testAppStateRefusesAnInstallWhileAJobWaits`, `testACheckIsRefusedWhileInstalling`.
- R5, the record is cleared so the message never repeats: `testANewBuildAtLaunchReportsInstalledOnceAndReturnsTheWatchingFlag`. Watching comes back on: `testAnInstallRecordsWatchingAndTheNextLaunchTurnsItBackOn`.
- R6, an unknown exit status is reported with its number: `testEachLiveExitPostsOneNoticeClearsTheRecordAndReturnsToIdle` (exit 9, signal 15).
- R7, mt-update gone without a new build: `testTheSameBuildWithMtUpdateGoneAtLaunchDidNotFinish`, `testAnInstallStillRunningAtLaunchIsRecheckedUntilItHasGone`. A recorded PID whose start time differs counts as gone: task 2's `isRunning` tests.

Choices
1. Rule 1 (spec Edge Cases, "About keeps a live failure on screen until the next check or install"). A check that starts clears `lastInstallError` together with `lastError`, as GitHub mode clears `lastError`. A successful install launch also clears it. Tests: `testACheckMapsEachOutcomeAndAFailureKeepsAnEarlierBuild`, `testInstallNowStartsTheInstallerAndSavesTheRecord`.
2. Rule 1 (R7, "so checks and Install Update are available again", the review round 1 finding). A failed or unfinished install puts the summary of the build it tried back into `availableBuildSummary`. The live exit passes the summary it started with, and the launch paths pass the record's. Right after a "did not finish" launch, Install is offered and the menu-bar badge shows an update, before any check. Tests: `testTheSameBuildWithMtUpdateGoneAtLaunchDidNotFinish`, `testAnInstallStillRunningAtLaunchIsRecheckedUntilItHasGone`.
3. Rule 4 (About text, visible once task 4 reads it). An install that did not finish (at launch or after the recheck) also keeps its notice text in `lastInstallError`, like a failure that ends while the app runs. About can then show it until the next check or install. flip at: `UpdateChecker+MtUpdate.swift: finishInstall(_:installing:)`, the `.didNotFinish` case. test: `testTheSameBuildWithMtUpdateGoneAtLaunchDidNotFinish`.
4. Rule 1 (spec Edge Cases, "a build that starts without mt-update leaves it alone"). `resumeAfterLaunch` in GitHub mode returns false and leaves the record in place. Test: `testNothingIsReportedWithoutARecordOrOutsideMtUpdateMode`.
5. Rule 6. The mt-update check refuses on `isChecking` and `isInstalling` and runs in its own `Task`. The GitHub path's private `checkTask` and its body stay untouched. Tests: `testACheckIsRefusedWhileInstalling`, `testACheckMapsEachOutcomeAndAFailureKeepsAnEarlierBuild` (asserts `isChecking` during the check).
6. Rule 6. The recheck is a `Task` that holds the checker weakly. Nothing stores or cancels it, and it ends once the evaluation is no longer "still running" or the checker is gone. A recheck that finds the record gone (it no longer decodes) returns to idle without a notice. That branch has no test, because only a damaged record reaches it.
7. Rule 6. While a launch finds the install still running, the summary is not restored. It comes back only if the install ends as a failure (Choices 2).
8. Rule 6. A launch that throws reports `error.localizedDescription` in the not-startable notice (for the provider's log error, "cannot open <path>: <reason>"). `lastInstallError` holds the whole notice body, as for live failures. Test: `testALaunchThatThrowsPostsNotStartableAndSavesNothing`.
9. Rule 6. The `AppState` wiring tests (an install refused while a job waits, and watching restored on the next launch) live in `UpdateCheckerMtUpdateTests.swift`, because `AppStateTests.swift` is outside this task's Touches.
10. Rule 6. The record's `startedAt` is taken just before the launch, and the record is saved right after it returns, on the main actor. A test fires the exit by hand after the save.

Follow-ups: none. No feature-map route changed (no view or menu change in this task).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 06ebe2860eb41e083f5e70ffcfbaa6fc09d65ac1, 832d711fbe510a5231dce7be94aab49a9650541f, 86901b1f260876bdf311573b35c346833f9b6b3a
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh-8-test-home swift test --parallel --filter 'MtUpdate|UpdateInstall|UpdateChecker|AboutSettingsView|MenuBarView|RPCUpdateStatus|RPCBadgeState|AppStateTests' (208 tests, rc 0), cd app/MeetingTranscriber && swift build --build-tests -Xswiftc -DAPPSTORE (rc 0), ./scripts/pre-push.sh (rc 0), ./scripts/lint.sh with the cached pinned tools (0 violations, 812 files)
- PRs: