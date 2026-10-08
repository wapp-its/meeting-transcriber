---
satisfies: [R2]
---
# gh-73-no-microphone-restart-after-the-capture.1 Reproduce a stall restart that builds a session after the capture stopped

## Description
Turn the CI flake into a failure that happens on every run, before any fix (spec Edge Cases and Early proof point). Two tests hold the handler's serial restart queue with a blocking item, so a stall restart is claimed and queued but cannot build its session until after `stop()` returned: a new manual-clock test in a new stop-race test file, and the existing timer test. On the current code both fail with the assertion CI reported; their post-release assertions are committed as strict expected failures so the suite stays green until task .2 removes the wrappers.

**Size:** S
**Files:** `tools/audiotap/Tests/MicCaptureHandlerStopRaceTests.swift` (new), `tools/audiotap/Tests/MicCaptureHandlerStallWatchdogTests.swift`
**Touches:** [tools/audiotap/Tests/MicCaptureHandlerStopRaceTests.swift, tools/audiotap/Tests/MicCaptureHandlerStallWatchdogTests.swift]

### Approach
- **Why a new file:** `MicCaptureHandlerStallWatchdogTests.swift` is at 577 lines against SwiftLint's 600-line `file_length` warning, which `./scripts/lint.sh` runs with `--strict`. New tests go into `MicCaptureHandlerStopRaceTests.swift`; the stall watchdog file only gets the timer test's hold, at most 15 added lines.
- **The new file** gets its own minimal private fakes, following `StallTestClock`, `StallTestSession` and `StallTestSessionQueue` (`MicCaptureHandlerStallWatchdogTests.swift:6-132`) and the copy gh-44 already made in `MicCaptureHandlerConfigChangeTests.swift:1-100` on its branch: a manual clock, a session that records its calls under a lock and can fail its bring-up (`shouldFail`, task .2 needs it), and a factory queue that counts every session built. Build the handler through the internal test-seam init with `stallWatchdogLimits` whose poll interval no test reaches (as `manualLimits`, `:154-160`) and the manual clock. Do not make the existing fakes non-private or refactor that file.
- **The manual-clock test** (`testAStallRestartQueuedWhenStopIsCalledBuildsNoSession` or similar), with sessions `[first, candidate]`: `try handler.start()`; enqueue `handler.restartQueue.async { gate.wait() }` with a `DispatchSemaphore(value: 0)` that a `defer` also signals, so a failing run never leaves the queue blocked; set the clock to start + 10 s; `pollStallWatchdog()` returns `.restart(silentSeconds: 10)`; `handler.stop()`; assert the session count is 1 (the schedule really was forced); signal the gate; `handler.restartQueue.sync {}`; spin the main run loop about 0.2 s; assert `handler.session` is still `first` (true before and after the fix).
- **Expected-failure scope:** inside one strict `XCTExpectFailure` closure (closure form, strict by default; precedent `app/MeetingTranscriber/Tests/EchoSegmentClassifierTests.swift:198`) go exactly the post-release R1 assertions: the session count is unchanged since the stop, and `candidate`'s recorded calls are empty. Before the fix the released attempt runs `hardwareFormat`, `installTap`, `start` and `teardown` on `candidate`, so both fail there. The schedule checks (the `.restart` decision, the count of 1 at stop) and the identity check stay outside the closure. The reason string says, in words, that a restart queued before stop still builds its session.
- **The timer test** `testTheTimerDrivesTheWatchdogAndStopsWithTheCapture` (`MicCaptureHandlerStallWatchdogTests.swift:480-501`): enqueue the same blocking item right after `try handler.start()` and before `waitUntil`. The timer cannot tick before the test yields the main run loop, so the item is always ahead of the stall restart's attempt. After `stop()` and `let built = fixture.sessions.count`, assert `built == 1` outside any wrapper, signal the gate, `handler.restartQueue.sync {}`, keep the existing 0.5 s spin, and wrap only the existing "no attempt after the stop" assertion (wording unchanged) in a strict `XCTExpectFailure`. Keep the real timer, its short limits and `realClock: true`.
- Observe the raw failure once with the wrappers temporarily removed (not committed): both tests fail with `XCTAssertEqual failed: ("2") is not equal to ("1")`. Put that output and the cause (a production race the test's timing exposes) in the done summary; task .2's commit message carries it (R3).

### Investigation targets
**Required** (read before coding):
- `tools/audiotap/Tests/MicCaptureHandlerStallWatchdogTests.swift:6-216,338-364,478-501` - the fakes to mirror, fixture, `waitUntil`, the existing stop tests, the timer test
- `tools/audiotap/Sources/MicCaptureHandler+Restart.swift:79-154` - claim, launch, and the attempt that builds its session before it asks the arbiter
- `tools/audiotap/Sources/MicCaptureHandler+StallWatchdog.swift:151-163` - the restart is charged before its attempt is queued
- `tools/audiotap/Sources/MicCaptureHandler.swift:177-205` - the internal test-seam init

**Optional** (reference as needed):
- `tools/audiotap/Tests/MicCaptureHandlerConfigChangeTests.swift:1-100` (gh-44) - the same private-fake copy, already lint-clean
- `app/MeetingTranscriber/Tests/EchoSegmentClassifierTests.swift:190-210` - expected-failure precedent

Line numbers are those on gh-44's branch head (`fix/gh-44-mic-restart-loop`, 6e259686), which this spec builds on; re-anchor by symbol if gh-44's pull request moved them.

### Key context
- `restartQueue` is an internal serial `DispatchQueue` (`MicCaptureHandler.swift:79-82`), reachable through `@testable import`. A block enqueued before the attempt holds the attempt behind it deterministically. Never block the main queue in these tests.
- The factory queue's count counts factory calls, so it is the observable for "built". The queue hands out a fresh session when its list is empty, which is why the count is asserted and not only the named sessions.
- SwiftFormat restyles a labelled closure argument into a trailing one; pass the factory and clock as typed locals (see `makeFixture`, `:173-176`).
- No fork issue number, spec id or `.local/` path in test names, comments, the expected-failure reason or the commit message (`.claude/rules/wapp-fork.md`: commits must read for the original's maintainers). Describe the race in words.
- Measured during planning in a scratch copy of gh-44's branch: the manual-clock version fails on every run with `("2") is not equal to ("1")`.
- Verify: `cd tools/audiotap && swift test --parallel --filter 'MicCaptureHandlerStopRaceTests|MicCaptureHandlerStallWatchdogTests' > /private/tmp/gh73-t1.log 2>&1`, then read the log (expected failures reported, suites pass). Lint with the cached pinned tools: `PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh`.
## Acceptance
- [ ] A manual-clock test in the new `MicCaptureHandlerStopRaceTests.swift` and the timer test each hold the restart queue so a stall restart is queued, not started, when `stop()` returns, and each asserts, outside any wrapper, that the session count at stop is 1 (the schedule was forced).
- [ ] With the expected-failure wrappers removed locally, both fail with `("2") is not equal to ("1")`; with them, both suites pass. The observed output and the cause are in the done summary.
- [ ] Exactly the post-release assertions are wrapped in strict `XCTExpectFailure` (the unchanged count and the candidate's empty calls in the new test; the existing "no attempt after the stop" assertion in the timer test); the timer test keeps its real timer, limits and assertion wording; no test is removed or skipped.
- [ ] The gate is released on every path; `MicCaptureHandlerStallWatchdogTests.swift` stays under 600 lines; `./scripts/lint.sh` is clean with the pinned tools.
## Done summary
Two tests now force the microphone stop race on every run. Each one holds the handler's serial restart queue with a blocking item, so a stall restart is claimed and queued before stop() and builds its session only after stop() returned. The new manual-clock test lives in tools/audiotap/Tests/MicCaptureHandlerStopRaceTests.swift with its own private fakes, and the session fake can fail its bring-up (shouldFail) for task .2. The existing timer test gets the same hold and keeps its real timer, limits and assertion wording. Each test asserts outside any wrapper that one session existed when stop() returned. The post-release assertions sit in strict XCTExpectFailure closures: unchanged count and empty candidate calls in the new test, and the "no attempt after the stop" assertion in the timer test.

Cause, as the reproduction shows: a production race that the timer test's real-clock timing only sometimes exposes. launchRestartAttempt hands the attempt to restartQueue, and runRestartAttempt's first step is sessionFactory(). stop() seals the arbiter and returns without waiting for that queue. An attempt queued but not yet started at stop() therefore builds its session, runs hardwareFormat, installTap and start on it, and only then learns from the arbiter that the capture is sealed. It then tears the session down without adopting it. The timer test waits only until the restart is charged, which happens before the queued attempt builds, so on a loaded runner the attempt starts after stop().

Observed raw failure, wrappers removed locally and not committed (serial swift test on the two tests, rc 1):
- MicCaptureHandlerStallWatchdogTests.swift:508: error: testTheTimerDrivesTheWatchdogAndStopsWithTheCapture : XCTAssertEqual failed: ("2") is not equal to ("1") - no attempt after the stop
- MicCaptureHandlerStopRaceTests.swift:153: error: testAStallRestartQueuedWhenStopIsCalledBuildsNoSession : XCTAssertEqual failed: ("2") is not equal to ("1") - no session is built after the stop
- MicCaptureHandlerStopRaceTests.swift:154: error: XCTAssertEqual failed: (["hardwareFormat", "installTap", "start", "teardown"]) is not equal to ([]) - the queued restart never touches its session

With the wrappers, the serial run reports each of the three as "XCTExpectFailure: matcher accepted" and passes. The focused suites passed 10 of 10 consecutive --parallel runs, with 13 tests collected each time. The reviewer independently ran them 20 of 20. MicCaptureHandlerStallWatchdogTests.swift is at 587 lines, and ./scripts/lint.sh with the pinned tools found 0 violations in 701 files. The gate is a DispatchSemaphore(value: 0) that a defer also signals, so a failing run never leaves the restart queue held.

Decisions:
- The review ran one correctness draw instead of three. The diff touches tests only, in one module, and changes no production concurrency. The reproduction was already measured deterministic (raw failure observed, 10 of 10 parallel runs).
- The fake's installTap takes a non-escaping block parameter. SwiftLint's unneeded_escaping rejects @escaping on an unused parameter, and the non-escaping method still satisfies the protocol requirement (the test target compiles).

baseline: green (swift test --parallel --filter 'MicCaptureHandlerStallWatchdogTests|RestartArbiterTests', 37 tests, rc 0; lint 0 violations)
Tier: session (jev-unavailable(no_key))

stage: impl-review - ran [2026-10-08T13:45Z..2026-10-08T13:51Z] (codex gpt-5.6-sol xhigh, one correctness draw, SHIP, no findings)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 9da38cce62ec8cc57d9c6965a4a9c1a85ef9a244
- Tests: cd tools/audiotap && swift test --parallel --filter 'MicCaptureHandlerStopRaceTests|MicCaptureHandlerStallWatchdogTests|RestartArbiterTests' (38 tests, rc 0), PATH=$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH ./scripts/lint.sh (0 violations, 701 files)
- PRs: