---
satisfies: [R2, R3, R4, R5, R6]
---
# gh-44-stop-the-microphone-restart-loop-on-a.3 Pace and cap configuration-change restarts in the capture handler

## Description
Route every `AVAudioEngineConfigurationChange` through `MicConfigChangePolicy` (task .2) so configuration-change restarts are paced and capped, and prove with fake sessions that the 21:51 loop cannot recur and that the stall watchdog then acts (spec R2–R6). Wiring and integration tests only; the judgement is task .2's.

**Size:** M
**Files:** `tools/audiotap/Sources/MicCaptureHandler.swift`, `tools/audiotap/Sources/MicCaptureHandler+ConfigChange.swift` (new), `tools/audiotap/Sources/MicCaptureHandler+Restart.swift`, `tools/audiotap/Sources/MicCaptureHandler+StallWatchdog.swift` (doc comment only), `tools/audiotap/Tests/MicCaptureHandlerConfigChangeTests.swift` (new)
**Touches:** [tools/audiotap/Sources/MicCaptureHandler.swift, tools/audiotap/Sources/MicCaptureHandler+ConfigChange.swift, tools/audiotap/Sources/MicCaptureHandler+Restart.swift, tools/audiotap/Sources/MicCaptureHandler+StallWatchdog.swift, tools/audiotap/Tests/MicCaptureHandlerConfigChangeTests.swift]

### Approach
- Write `MicCaptureHandlerConfigChangeTests` first; the loop test must fail on today's code (every call to `handleEngineConfigChange()` builds a session), then implement.
- Move `installConfigChangeObserver()` (`MicCaptureHandler.swift:380-391`) and `handleEngineConfigChange()` (`:393-396`) into the new `MicCaptureHandler+ConfigChange.swift` (pattern: `+StallWatchdog.swift`, its own file-private `logger` with category `MicCapture`). `handleEngineConfigChange()` becomes internal so tests drive it like `pollStallWatchdog()`. `MicCaptureHandler.swift` is 583 lines against the 600 lint cap: the move is what makes room for the new state.
- New stored state in `MicCaptureHandler.swift`, main-queue confined like `session` (say so in a doc comment): `var configChangePolicy: MicConfigChangePolicy` and `var pendingConfigChangeRestart: DispatchWorkItem?`. Add `configChangeLimits: MicConfigChangePolicy.Limits = .production` as the LAST parameter of the internal test-seam `init` (`:174-196`; `function_default_parameter_at_end`), mirroring `stallWatchdogLimits`. The public convenience init is unchanged.
- Engine start bookkeeping: `start(deviceUID:)` (`:202-209`) records `configChangePolicy.engineStarted(at: stallClock())` after the start succeeded; `adopt` (`MicCaptureHandler+Restart.swift:148-177`) records it with `adoptedAt` and calls `cancelPendingConfigChangeRestart()` once the arbiter said `.adopt`.
- `handleEngineConfigChange()`: ask `configChangePolicy.decide(at: stallClock(), restartPending: pendingConfigChangeRestart != nil)`. `.restart(0)` → launch now; `.restart(d)` → schedule one `DispatchWorkItem` with `DispatchQueue.main.asyncAfter(deadline: .now() + d, execute:)` that clears the pending slot and launches; `.ignore(_, log:)` → log when `log` is true, nothing else. Launch = the existing `handleDeviceChange(.configurationChanged)` path; make `handleDeviceChange` `@discardableResult` returning whether the arbiter granted an attempt (`+Restart.swift:26-32`), and call `configChangePolicy.restartLaunched(at:)` only when it returns true. Existing call sites and tests keep compiling unchanged.
- One helper in the new extension, `cancelPendingConfigChangeRestart()`, cancels and clears the pending item; call it from `stop()` (`MicCaptureHandler.swift:403-447`), from `adopt`, and from both give-up paths (`MicCaptureHandler+Restart.swift:181-194` and the `.giveUp` arm at `:215-220`).
- Logging (R5): use task .2's line helpers. Write the restart line when the decision is taken in `handleEngineConfigChange()` ("restarting now" or "restarting in N s"), not when a delayed item fires, so its timing and its seconds-since-start are the notification's. Restart decision at `.notice`, pending ignore at `.notice`, cap ignore at `.error`, all `privacy: .public` (no UID in them). Delete the old info line "engine configuration changed (format/route change)". Keep "listening for engine configuration changes".
- Doc comments: update `handleDeviceChange`'s comment (`+Restart.swift:17-25`) and `MicRestartTrigger.configurationChanged` (`+StallWatchdog.swift:13-14`) to say configuration-change restarts are paced and capped by `MicConfigChangePolicy`, and why (the pin loop).

### Investigation targets
**Required** (read before coding):
- `tools/audiotap/Sources/MicCaptureHandler.swift:1-210,361-448` — state ownership notes, init, start, observers, stop
- `tools/audiotap/Sources/MicCaptureHandler+Restart.swift:1-247` — claim, launch, adopt, give-up paths
- `tools/audiotap/Sources/MicCaptureHandler+StallWatchdog.swift:1-169` — trigger enum and how the watchdog claims through the same arbiter
- `tools/audiotap/Tests/MicCaptureHandlerStallWatchdogTests.swift:14-229,305-345` — fake session, session queue, manual clock, fixture, `waitUntil`, the one-attempt tests to extend in spirit

**Optional** (reference as needed):
- `tools/audiotap/Sources/RestartArbiter.swift:129-182` — which events are ignored in which phase
- `tools/audiotap/Tests/MicCaptureHandlerWedgeTests.swift` — more fake-session usage

### Key context
- The fakes in `MicCaptureHandlerStallWatchdogTests.swift` are `private`; build a minimal private fake in the new test file following that shape (records calls and device UIDs, keeps the tap block, `notificationObject`), rather than refactoring the existing test file.
- Use a manual clock like `StallTestClock` and test limits with tiny real-time backoffs, e.g. `Limits(windowSeconds: 60, maxRestartsPerWindow: 3, backoffSeconds: [0, 0.05, 0.1])`; stall-watchdog limits as `manualLimits` (`MicCaptureHandlerStallWatchdogTests.swift:163-169`) so only explicit `pollStallWatchdog()` calls tick.
- Drive the loop deterministically: after each adoption (`waitUntil` the new session is live), call `handler.handleEngineConfigChange()`; do not rely on a fake that posts by itself on a timer.
- Tests to include: (1) the 21:51 pattern: a change after every adoption yields exactly 1 + 3 sessions, a fourth change builds nothing (spin the run loop ~0.3 s to be sure), then with the manual clock at last adoption + 15 s `pollStallWatchdog()` returns `.restart` and a further session is adopted; (2) the first change in a window restarts at once (production limits) exactly as today; (3) a second change within the window waits for its backoff (nothing at once, adopted after it); (4) a change while a delayed restart is pending adds nothing (one extra session only); (5) `stop()` with a pending delayed restart builds nothing afterwards; (6) a default-input change adopted while a delayed restart is pending cancels it; (7) with a pinned, present device every configuration-change restart (immediate and delayed) targets that device UID; (8) posting the real `.AVAudioEngineConfigurationChange` with the live session's `notificationObject` reaches the policy and restarts; (9) a change while a stall restart's attempt is in flight launches nothing and charges nothing (policy budget unchanged); hold the candidate inside `hardwareFormat` with a semaphore, as `StallTestSession.shouldWedge` does, and release it before the test ends.
- R6: `MicCaptureHandlerStallWatchdogTests`, `MicCaptureHandlerWedgeTests`, `MicCaptureHandlerStopTests`, `MicEngineSessionSeamTests`, `RestartArbiterTests` must pass without edits.
- Verify: `cd tools/audiotap && CFFIXED_USER_HOME=/private/tmp/gh44-home swift test --parallel --filter 'MicCaptureHandler|MicConfigChangePolicyTests|MicEngineSessionSeamTests|RestartArbiterTests' > /private/tmp/gh44-t3.log 2>&1`, read the log; then the full audiotap suite once (`swift test --parallel > /private/tmp/gh44-t3-full.log 2>&1`); `./scripts/lint.sh` with the pinned tools. The app package consumes AudioTapLib by path, so also build it once: `cd app/MeetingTranscriber && swift build > /private/tmp/gh44-t3-app-build.log 2>&1`.
## Acceptance
- [ ] `MicCaptureHandlerConfigChangeTests` cover cases (1)–(9) of the task; the 21:51 loop test fails on the code before this task and passes after it.
- [ ] Every `AVAudioEngineConfigurationChange` goes through `MicConfigChangePolicy`; only arbiter-granted launches are charged; a pending delayed restart is cancelled through one helper by stop, by either give-up path and by any adoption.
- [ ] Configuration-change restarts target the pinned device while it is present (unchanged rule, now covered for delayed restarts).
- [ ] The info line "engine configuration changed (format/route change)" is gone; the new lines are notice/error level, public, and UID-free.
- [ ] `MicCaptureHandler.swift` stays under 600 lines; the existing audiotap suites pass without edits; the full audiotap suite and `swift build` of `app/MeetingTranscriber` succeed (log files read); `./scripts/lint.sh` clean with the pinned tools.
## Done summary
A configuration change can no longer spin the microphone capture in a restart loop. `MicCaptureHandler` sends every `AVAudioEngineConfigurationChange` through `MicConfigChangePolicy`. A change after every engine start (the 21:51 pattern) now builds 1 + 3 sessions in a 60 s window. After that, the stall watchdog restarts the capture once its 15 s grace and its 10 s stall time have passed.

What changed (commits 36e5ed5b fix and ebe6acea test, all files inside the task's Touches):
- New file `tools/audiotap/Sources/MicCaptureHandler+ConfigChange.swift`.
  - It holds `installConfigChangeObserver()` (moved) and `handleEngineConfigChange()` (moved, now internal), plus the new `cancelPendingConfigChangeRestart()`.
  - A `.restart(0)` decision launches at once. A `.restart(d)` decision schedules one `DispatchWorkItem` on the main queue, which clears the pending slot and then launches.
  - An ignore decision only logs, and only when the policy asks for a line.
- `handleDeviceChange` is now `@discardableResult -> Bool`. The handler calls `restartLaunched(at:)` only when it returns true, so a launch the arbiter declines charges nothing. Existing call sites compile unchanged.
- `start(deviceUID:)` and `adopt` record `engineStarted(at:)`. `adopt` also drops a pending restart. `stop()`, `handleAttemptTimeout` and the `.giveUp` arm of `scheduleRestartRetry` drop it through the same helper.
- Log lines (R5) use the policy's `logLine(for:at:)`, rendered right after `decide` and before `restartLaunched`.
  - The restart line and the pending line go out at notice, the cap line at error. All are `privacy: .public` and carry no UID.
  - The info line "engine configuration changed (format/route change)" is deleted. "listening for engine configuration changes" stays.
- `MicCaptureHandler.swift` is 576 lines (was 583). The test-seam `init` gains `configChangeLimits:` as its last parameter, defaulting to `.production`. The public convenience init is unchanged.
- Doc comments on `handleDeviceChange` and `MicRestartTrigger.configurationChanged` say that these restarts are paced and capped, and why.

Tests are in `tools/audiotap/Tests/MicCaptureHandlerConfigChangeTests.swift`, 10 cases:
1. `testAChangeAfterEveryStartStopsAtTheCapAndTheStallWatchdogThenRestarts`: the 21:51 loop (R2, R3)
2. `testTheFirstChangeInAWindowRestartsAtOnce`: production limits (R2)
3. `testASecondChangeInTheWindowWaitsForItsBackoff` (R2)
4. `testAChangeWhileARestartIsPendingAddsNothing` (R2)
5. `testStopDropsAPendingRestart`: R2 error case, stop
6. `testAnAdoptionDropsAPendingRestart`: R2 error case, adoption. It also covers R6, since a default-input restart is not charged.
7. `testEveryConfigChangeRestartTargetsAPresentPinnedDevice`: R4, immediate and delayed
8. `testTheEnginesNotificationReachesThePolicy`: the real notification, posted from a background queue on the session's `notificationObject`
9. `testAChangeDuringAStallRestartLaunchesAndChargesNothing`: R2 error case, only arbiter-launched restarts count
10. `testEitherGiveUpDropsAPendingRestart`: R2 error case, give-up. It runs both paths, retry budget spent and attempt never returns. It takes about 5 s because `RestartArbiter.attemptTimeout` is a fixed constant.

Measured:
- baseline: green. Before any edit, at 78d923c9, the focused filter exited 0 with 73 tests and lint exited 0 (/private/tmp/gh44-t3-baseline.log, /private/tmp/gh44-t3-lint-baseline.log).
- Red run before the fix. Cases 1 to 9 ran against today's behaviour plus only the seams they need to compile (the stored state, the init parameter, and `handleEngineConfigChange` made internal with its old body).
  - The run exited 1, with 7 of 9 tests failing.
  - The loop test failed with `("5") is not equal to ("4") - 1 + 3 sessions: the fourth change in the window builds nothing`.
  - The stall watchdog returned nil at last adoption + 15 s (/private/tmp/gh44-t3-red.log).
- Mutation check for case 10. With the cancel call removed from both give-up paths, the test failed on both (/private/tmp/gh44-t3-giveup-mutant.log). The source was restored before the commit.
- Green on the final tree:
  - The focused filter `MicCaptureHandler|MicConfigChangePolicyTests|MicEngineSessionSeamTests|RestartArbiterTests` exited 0 with 83 tests (/private/tmp/gh44-t3.log).
  - Cases 1 to 9 passed 3 repeat runs (/private/tmp/gh44-t3-repeat-1.log to -3.log).
  - The full audiotap suite exited 0 with 516 tests (/private/tmp/gh44-t3-full.log).
  - `./scripts/lint.sh` with SwiftFormat 0.63.0 and SwiftLint 0.65.1 exited 0 with 0 violations (/private/tmp/gh44-t3-lint.log).
  - The `app/MeetingTranscriber` `swift build` exited 0 on 36e5ed5b. The later commit only adds a test (/private/tmp/gh44-t3-app-build.log).
- R6: these suites pass without edits: `MicCaptureHandlerStallWatchdogTests`, `MicCaptureHandlerWedgeTests`, `MicCaptureHandlerStopTests`, `MicEngineSessionSeamTests` and `RestartArbiterTests`.

Not run: the owner's pinned-headset check from the spec's Verification. It needs the owner's Jabra and a real call.

Decisions:
- I added case 10 beyond the task's nine cases. R2's errors and the AC name both give-up paths, and no listed case would catch a missing call there.
- The fix, the move and cases 1 to 9 land in one commit. A test-only commit would not compile without the seams, and the red run above is the proof that the loop test failed first. Case 10 is its own commit.
- Case 2 holds the candidate inside `hardwareFormat` before it asserts `.attemptInFlight`. The red run showed that an instant fake can reach `.committing` before the main thread reads the phase.
- I read the Phase 1b bridge reference only after implementing. The implementer was the in-host session model, so the bridge branch was inert and the late read changed nothing.

stage: impl-review - ran [2026-10-06T22:19Z..2026-10-06T22:27Z] SHIP, 3-lens panel, no findings (model: codex gpt-5.6-sol xhigh)

Tier: session (jev-unavailable(no_key)) · actual model: claude-opus-5-5

Integrated onto fix/gh-44-mic-restart-loop as b381e300 + 498b858e (cherry-picks of 36e5ed5b + ebe6acea; identical tree 65a3b80b). Integrated verify: cd tools/audiotap && swift test --parallel --filter MicCaptureHandler|MicConfigChangePolicyTests|MicEngineSessionSeamTests|RestartArbiterTests|MicPinSettleTests (93 tests, exit 0; /private/tmp/gh44-int3.log).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: b381e30082cb6f7c10f0a575b5ec1dcfc773946b, 498b858eaa8025b263a5c717f1068530fbcedaf5
- Tests: cd tools/audiotap && CFFIXED_USER_HOME=/private/tmp/gh44-home swift test --parallel --filter 'MicCaptureHandler|MicConfigChangePolicyTests|MicEngineSessionSeamTests|RestartArbiterTests|MicPinSettleTests' (93 tests, exit 0), cd tools/audiotap && swift test --parallel (full audiotap suite, 516 tests, exit 0; worker run on the identical tree 65a3b80b), cd app/MeetingTranscriber && swift build (exit 0; worker run on the identical tree), PATH=/private/tmp/gh44-lint-tools/bin:$PATH ./scripts/lint.sh (exit 0, 0 violations; worker run on the identical tree)
- PRs: