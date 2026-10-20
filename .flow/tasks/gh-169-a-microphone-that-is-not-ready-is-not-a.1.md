---
satisfies: [R1, R2, R3, R4]
---
# gh-169-a-microphone-that-is-not-ready-is-not-a.1 Implement A microphone that is not ready is not a broken permission

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
A microphone that has no input device, or one that reports a format of 0 Hz or 0 channels, no longer counts as a broken grant. The permission check now also runs after a wake from sleep and after a change of the default input device. Only one check runs at a time, and no check opens the microphone while a recording captures.

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

stage: impl-review - ran [2026-10-20T18:19:40Z..2026-10-20T18:23:58Z] (model: gpt-6-astra, effort xhigh, 3 draws correctness/contracts/integration, all SHIP, 0 findings; receipt /tmp/impl-review-receipt-24027fe6cd7a-gh-169-a-microphone-that-is-not-ready-is-not-a.1.json)

### Commits

- 22cf2615 test(app): pin the permission re-check a microphone that is not ready needs (failing tests + seams that keep today's behaviour)
- 1360ff30 fix(app): stop calling a microphone that is not ready a broken grant

### Changes per file

- `Sources/PermissionHealthCheck+MicrophoneRetry.swift`: `MicProbeFailure.isInconclusive` (noInputDevice, invalidFormat); `MicProbeOutcome.leavesGrantStanding` / `logToken`; the retry's outcome decides when both attempts fail; `mayRetry` is asked after the 2 s pause and before the second probe, and a "no" ends the check with no verdict (nil). The per-attempt unified-log line is unchanged and still names the reason.
- `Sources/PermissionHealthCheck.swift`: `runLive(mayRetryMicrophone:) -> HealthCheckResult?`; `runLive()` stays for `WatchLoop`'s pre-start gate with the retry always allowed.
- `Sources/PermissionsController.swift`: one-check-at-a-time runner (`running` task, one folded follow-up), deferral while `recordingActive` with one check after it, gave-way check is not stamped for the debounce, `recheck()` (debounced by `recheckInterval` = 3 s), `recheckAfterWake(center:)` (idempotent observer), `setRecordingActive(_:)`; probe and clock seams.
- `Sources/MicrophoneController.swift`: `onDefaultInputChanged` callback from the existing default-input HAL listener.
- `Sources/AppState+PermissionChecks.swift` (new): `startPermissionChecks()` installs the wake and input-change triggers and runs the launch check.
- `Sources/MeetingTranscriberApp.swift`: launch `.task` calls `startPermissionChecks()`; activation calls `permissions.recheck()`.
- `Sources/WatchingController.swift` / `WatchingController+LocalModel.swift`: `permissions` is internal; `recordingActivityChanged()` pushes `isRecordingActivity` to the permission check (outside `#if !APPSTORE`, without record-only).
- Tests: `PermissionsControllerRecheckTests.swift` (new: wake replaces broken verdict; events fold into one follow-up and a stale failure cannot win; recording before the retry gets no second probe and one check after; a new recording defers again; Stop Watching still finishing counts as capturing), `PermissionsControllerTests.swift` (R1 table test), seam call-site updates in `PermissionsControllerNotificationTests.swift` and `XCTestCase+WatchingController.swift`. No assertion was weakened.

### Defect route

- prior-fix check: `git log` on the three permission files: last fix in the area 7e3e1bbe (retry the microphone check once before calling it broken), no reverts. Open fork PRs: none. Original repo: no open PR or issue matching "permission health microphone" / "microphone permission broken". Memory (bug track): `async-probe-result-adopted-after-its-2026-10-09` (adopt an async probe result only while its precondition still holds) applied: the retry re-asks the recording state after its pause.
- introduced by: skipped: no known-good revision.
- base (red): 22cf2615, focused permission suites 82 tests, 6 failed for the stated reasons (R1: broken + "Permission Problem" for invalidFormat x2, noInputDevice x2, [noBuffer, invalidFormat]; wake: no second check, attempts 2 != 3; fold: 3 probes side by side, stale failure won; retry: retry opened the mic during the recording, attempts 3 != 2, and the gave-way check was stamped; defer-again: check ran during the recording; Stop Watching: a check ran while the capture finished).
- head (green): 1360ff30, same suites 82/82 pass.

### Decisions

1. ASSUME: when both probe attempts fail differently, the retry's failure decides (rule 5) · alternatives: B - any no-buffer attempt makes it broken; C - the first attempt decides · flip at: `PermissionHealthCheck+MicrophoneRetry.swift:probeWithOneRetry` · test: `testAMicrophoneThatIsNotReadyIsNotReportedAsABrokenGrant`
2. `tapInstallFailed` / `engineStartFailed` stay evidence of a broken grant (rule 1: R1 names only a missing device and a zero format as inconclusive).
3. Every request is gated by the recording, the activation re-check included, and all go through the one runner (rule 1: R3 "no check ... while a recording captures").
4. ASSUME: no generation counter; "latest result wins" holds by construction because checks run one at a time and are applied in start order (rule 5/6) · alternatives: B - a generation id per check, discard on mismatch · flip at: `PermissionsController.swift:runOneCheck` · test: `testEventsDuringARunningCheckFoldIntoOneFollowUpAndAStaleFailureCannotWin`
5. The folded follow-up and the check after a recording are not debounced (rule 1: R2 "start at most one further check after it", R3 "one check runs after capture finished").
6. A check that gave way to a recording does not stamp `lastCheckAt` (rule 1: R3 "ends without verdict").
7. The default-input trigger reuses `MicrophoneController`'s existing HAL listener through a callback instead of a second listener (rule 1/6).
8. Triggers are installed from the menu-bar `.task` via `AppState.startPermissionChecks()`, not from `AppState.init`, so tests that construct `AppState` install no observers (rule 6).
9. `WatchLoop`'s pre-start gate keeps its own live check with the retry always allowed: it runs while that start already counts as the recording, and the spec leaves the probe unchanged (rule 1).
10. Badge input is asserted through `controller.health?.isHealthy`, which `AppState.hasPermissionProblem` reads (rule 6).
11. Existing tests changed only at seam call sites (probe closure takes the retry question); no assertion changed.

### Verification (all run on the committed content, worktree root /Users/flach/.ai-sync/worktrees/-Users-flach-Sources-meeting-transcriber/gh-169-a-microphone-that-is-not-ready-is-not-a)

- baseline: green (focused permission suites, 76 tests, suite_rc=0, before any edit)
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch>/home swift test --parallel --filter 'PermissionHealthCheckTests|PermissionHealthCheckAccessibilityTests|PermissionsControllerTests|PermissionsControllerNotificationTests|PermissionsControllerRecheckTests'` -> 82 tests, 0 failures, suite_rc=0
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch>/home swift test --parallel --filter 'WatchingController|MicrophoneController|AppState|LocalModelRecordingPreemption|RPCRecordStatus|ManualRecording|DebugRPCServerIntegration'` -> 342 tests, 0 failures, suite_rc=0
- App Store variant: `swift test --parallel -Xswiftc -DAPPSTORE --filter '<the five permission suites>'` -> 82 tests, 0 failures, suite_rc=0
- `PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh` -> 0/925 files need formatting; "Found 0 violations, 0 serious in 904 files"
- `xcodebuild -scheme MeetingTranscriber -destination 'platform=macOS' -derivedDataPath <scratch>/dd SWIFT_SUPPRESS_WARNINGS=NO clean build-for-testing` -> TEST BUILD SUCCEEDED; no compiler warning in a changed file
- `swiftlint analyze --strict --compiler-log-path <scratch>/xcodebuild.log` -> "Found 0 violations, 0 serious in 825 files"
- `./scripts/pre-push.sh` -> rc 0 (release Homebrew build, local model helper build and tests); `swift build -c release -Xswiftc -DAPPSTORE` -> rc 0
- `flowctl gate classify --base 13c3a8e9` -> FULL (code); the focused Quick commands above are the gate.

### Follow-ups (not filed by this worker)

1. A probe that never returns (an AVAudioEngine start wedged in the HAL, as seen in capture restarts) now holds the one-check runner, so no later check runs until relaunch; before, a later check could still start beside it. The probe has no outer deadline today. Worth a bounded probe or a runner deadline.
2. Live proof on hardware (wake with a Bluetooth headset, default input switch) is not part of this task; unit tests only, per the brief.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 22cf2615cc399ce18c15085c91be47edc33b32d8, 1360ff301f60000095bc6e83a82880d1e5007c2b
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch>/home swift test --parallel --filter 'PermissionHealthCheckTests|PermissionHealthCheckAccessibilityTests|PermissionsControllerTests|PermissionsControllerNotificationTests|PermissionsControllerRecheckTests' (82 tests, 0 failures), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch>/home swift test --parallel --filter 'WatchingController|MicrophoneController|AppState|LocalModelRecordingPreemption|RPCRecordStatus|ManualRecording|DebugRPCServerIntegration' (342 tests, 0 failures), swift test --parallel -Xswiftc -DAPPSTORE --filter '<five permission suites>' (82 tests, 0 failures), ./scripts/lint.sh (0 violations), xcodebuild clean build-for-testing + swiftlint analyze --strict (0 violations), ./scripts/pre-push.sh (rc 0) + swift build -c release -Xswiftc -DAPPSTORE (rc 0)
- PRs: