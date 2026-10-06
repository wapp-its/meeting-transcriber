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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
