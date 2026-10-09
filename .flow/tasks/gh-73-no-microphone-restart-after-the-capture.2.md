---
satisfies: [R1, R2, R3]
---
# gh-73-no-microphone-restart-after-the-capture.2 Refuse a restart session that would be built after the capture stopped

## Description
The fix (spec Architecture, R1 to R3): the restart attempt checks the arbiter and builds its session inside one critical section that `stop()`'s seal also takes, so an attempt queued before `stop()` builds nothing afterwards, and the logs name why. Task .1's expected-failure wrappers then come off, which shows R2's "fails without the guard, passes with it", and the audiotap target runs 20 times in a row under parallel execution.

**Size:** M
**Files:** `tools/audiotap/Sources/RestartArbiter.swift`, `tools/audiotap/Tests/RestartArbiterTests.swift`, `tools/audiotap/Sources/MicCaptureHandler.swift`, `tools/audiotap/Sources/MicCaptureHandler+Restart.swift`, `tools/audiotap/Tests/MicCaptureHandlerStopRaceTests.swift`, `tools/audiotap/Tests/MicCaptureHandlerStallWatchdogTests.swift` (wrapper removal only)
**Touches:** [tools/audiotap/Sources/RestartArbiter.swift, tools/audiotap/Tests/RestartArbiterTests.swift, tools/audiotap/Sources/MicCaptureHandler.swift, tools/audiotap/Sources/MicCaptureHandler+Restart.swift, tools/audiotap/Tests/MicCaptureHandlerStopRaceTests.swift, tools/audiotap/Tests/MicCaptureHandlerStallWatchdogTests.swift]

### Approach
- Tests first: add the arbiter's new cases to `RestartArbiterTests` and see them fail; task .1's handler tests are already red once their wrappers are removed.
- `RestartArbiter` (`RestartArbiter.swift:110-127`, next to `mayCreateOutputFile` and `isCapturing`), read-only additions only, no phase or transition changes:
  - `func mayBuildAttempt(generation: Int) -> Bool`, true only when `phase == .attemptInFlight(generation: generation)`, with a doc comment saying why (an attempt queued before a stop or a give-up must not bring up an engine afterwards).
  - One answer for which seal holds, for example `var seal: Seal?` with `enum Seal { case stopped, gaveUp }` (nil while not sealed). Both log lines below take their reason from it, so the stopped-or-gave-up choice exists once (spec A5).
  - `RestartArbiterTests` (style of `:15-60`): `mayBuildAttempt` true for the launched generation; false after `.stopRequested` during the attempt, after `.attemptTimedOut` (give-up), for an older generation, while backing off, and while committing. The seal answer is nil while capturing or in flight, `.stopped` after a stop, `.gaveUp` after a timeout or an exhausted retry budget.
- `MicCaptureHandler.swift`: one stored property, a dedicated lock (for example `let attemptBuildLock = NSLock()`), whose doc comment states who takes it (only `stop()`'s seal and the attempt's check-and-build), the lock order (it, then `arbiter`, never the reverse) and that the session factory runs under it and must never call back into the handler. In `stop()` (`:395-402`) take it around the `.stopRequested` seal only; nothing else in `stop()` moves. The file is at about 576 of 600 lines, so keep the addition to a few lines.
- `MicCaptureHandler+Restart.swift`, `runRestartAttempt` (`:110-113`): replace the bare `sessionFactory()` with the check-and-build under the new lock (the `arbiter.withLock { $0.mayBuildAttempt(generation:) }` read and the factory call both inside it). When refused, log at `.notice` that restart attempt <generation> after <`trigger.logDescription`> is not built because the capture was stopped or gave up first (reason from the arbiter's seal answer), and return with no other side effect: the arbiter already records the stop or give-up.
- Same file, the `default:` arm (`:148-153`): read the seal answer in the critical section that returned `.rejectStale` (or right after it) and log at `.notice` that the attempt returned after the capture was stopped or gave up and its session is torn down, replacing "outlived its deadline". In `adopt` (`:168-171`) raise "discarding a restart that succeeded after the session was sealed" from `.info` to `.notice`. No device UID or name in any of these; `privacy: .public`.
- Tests: remove task .1's two `XCTExpectFailure` wrappers (one in each file) and keep the assertions verbatim. Add two cases to `MicCaptureHandlerStopRaceTests.swift`, with its fakes from task .1: (a) a default-input-change restart (`handler.handleDeviceChange(.defaultInputChanged)`) queued behind the gate when `stop()` runs builds nothing, because the guard sits on the path every trigger shares; (b) a stall restart whose session fails its bring-up (`shouldFail`) under a short retry schedule passed as `decideRetry:` (as `testAStallRestartStaysOnAPresentPinnedDeviceThroughFailures` does, `MicCaptureHandlerStallWatchdogTests.swift:429-461`), stopped once `handler.arbiter.withLock { $0.phase }` reads `.backingOff` (so the retry is waiting out its backoff), then spun past the retry delay, builds nothing more after `stop()`; this one passes before and after the change and pins R1's "including".
- Commit message (R3): states that the reproduction showed a production race (an attempt queued before stop built and started a session after stop returned; the test's timing decided how often CI saw it) and how the guard closes it, written for the original's readers (no fork issue numbers or spec ids).

### Investigation targets
**Required** (read before coding):
- `tools/audiotap/Sources/RestartArbiter.swift:27-183` - phases, the transition table, the existing read-only questions
- `tools/audiotap/Sources/MicCaptureHandler+Restart.swift:107-189` - the attempt, its stale arm, adoption
- `tools/audiotap/Sources/MicCaptureHandler.swift:16-30,70-91,395-440` - state ownership notes, `arbiter`, `restartQueue`, `isRecording`, `stop()`
- `tools/audiotap/Tests/RestartArbiterTests.swift:1-60,124-160` - layout and the stop cases
- `tools/audiotap/Tests/MicCaptureHandlerStopRaceTests.swift` - after task .1

**Optional** (reference as needed):
- `tools/audiotap/Tests/MicCaptureHandlerWedgeTests.swift:327-356` - the existing "attempt succeeds after a stop is discarded" test, which must stay green
- `tools/audiotap/Sources/MicEngineSession.swift:83-140` - the production factory only allocates an `AVAudioEngine`

Line numbers are those on gh-44's branch head (6e259686); re-anchor by symbol if gh-44's pull request moved them.

### Key context
- Do not hold the arbiter's lock across `sessionFactory()`: the render thread reads it for every buffer (`isRecording`, `MicCaptureHandler.swift:89-91`), and `OSAllocatedUnfairLock` aborts on re-entry.
- Do not make `stop()` wait on `restartQueue`: an attempt can wedge forever in `hardwareFormat` (upstream issue #588), so `stop()` may block only for the short check-and-build.
- An attempt that passed the guard before `stop()` keeps today's behaviour (brought up, refused on return, torn down on the restart queue). That is R1's error clause; do not add per-engine-call checks (spec Boundaries).
- Measured during planning: a prototype of this guard (check and factory in one critical section) made the reproduction pass and kept all 517 audiotap tests green in about 22 s per run.
- R2 run: `cd tools/audiotap && for i in $(seq 1 20); do swift test --parallel > /private/tmp/gh73-run-$i.log 2>&1 || echo "run $i FAILED"; done`, then confirm in every saved log file that the stop-race tests and the timer test passed (search the files; never pipe the test run itself).
- Revert check for R2: temporarily restore the bare factory call, run the two suites, see task .1's tests fail with `("2") is not equal to ("1")`, restore the guard. Not committed.
- Log check: after running the stop-race suite, `/usr/bin/log show --last 10m --predicate 'subsystem == "com.meetingtranscriber.audiotap" AND category == "MicCapture"'` shows the new notice lines (notice is retained, info is not).
- The app consumes AudioTapLib by path, so build it once: `cd app/MeetingTranscriber && swift build > /private/tmp/gh73-app-build.log 2>&1`, and read the log.
- Lint: `PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh`.
## Acceptance
- [ ] `RestartArbiter.mayBuildAttempt(generation:)` and the seal answer exist with tests (the query true for the in-flight generation and false when stopped, given up, superseded, backing off, committing; the seal nil, stopped, gave up as listed); no phase or transition changed.
- [ ] The restart attempt checks and builds in one critical section on a dedicated lock that `stop()`'s seal also takes; the arbiter's lock is never held across the factory; the lock order is documented; `stop()` does not wait on the restart queue.
- [ ] Task .1's two tests pass without their wrappers and fail with `("2") is not equal to ("1")` when the guard is reverted locally; the default-input and pending-retry cases pass; `MicCaptureHandlerWedgeTests`, `MicCaptureHandlerStopTests`, `MicCaptureHandlerConfigChangeTests` and the rest of the audiotap target pass without edits.
- [ ] 20 consecutive `swift test --parallel` runs of the audiotap target are green, every log read; refused and late attempts log at notice level with the reason from the seal answer and no device UID, seen in `log show`.
- [ ] `./scripts/lint.sh` is clean with the pinned tools; `MicCaptureHandler.swift` and both test files stay under 600 lines; `swift build` of `app/MeetingTranscriber` succeeds; the commit message records the cause the reproduction showed.
## Done summary
A microphone capture that is stopped while a restart is still queued no longer opens the microphone after stop() returns. The restart attempt now asks the restart arbiter whether its generation is still the attempt in flight, and builds its session, inside one critical section on a new `MicCaptureHandler.attemptBuildLock` that stop()'s seal also takes. An attempt queued before stop() builds nothing afterwards, on every trigger (stall, default-input change, configuration change, retries), because they all build through `runRestartAttempt`.

What changed:
- `RestartArbiter.mayBuildAttempt(generation:)` (true only for `.attemptInFlight(generation)`) and `RestartArbiter.seal` (`.stopped`, `.gaveUp`, nil) are read-only additions. No phase or transition changed.
- `attemptBuildLock` is an NSLock. Its doc comment names who takes it, the lock order (it, then `arbiter`) and that the session factory runs under it. stop() takes it around the `.stopRequested` seal only and still never waits on the restart queue. The attempt copies the arbiter state under the arbiter's lock and releases that lock before the factory runs.
- Logs, all notice level with no device UID or name. A refused attempt logs "Mic: not building restart attempt N after <trigger>: the capture was stopped first" (or "gave up"). A late return logs "Mic: restart attempt N after <trigger> returned after the capture was stopped; tearing its session down" in place of "outlived its deadline". The adoption-refused line moved from info to notice. One helper (`sealReason`) maps the seal to text for both new lines.
- Tests. Task .1's two XCTExpectFailure wrappers are gone and their assertions are unchanged. `RestartArbiterTests.testOnlyTheAttemptStillInFlightMayBuildItsSession` and `testTheSealSaysWhetherTheCaptureWasStoppedOrGaveUp` are table-driven over launched, stopped, given up, superseded, newer, backing off and committing, and over nil, stopped and gave up. `MicCaptureHandlerStopRaceTests.testADefaultInputRestartQueuedWhenStopIsCalledBuildsNoSession` was red before the guard and is green after. `testARetryWaitingOutItsBackoffWhenStopIsCalledBuildsNoSession` is green before and after and pins R1's "including".

Evidence:
- Red with the arbiter API present and the guard absent. Four failures, all `("2") is not equal to ("1")` (StopRace :172, its candidate-calls line :173, :193, StallWatchdog :508).
- Revert check after the fix, with the bare factory call restored locally and not committed. The same four failures appeared, and the guard was restored byte-identical.
- Focused suites with the guard. 61 tests (RestartArbiter 27, StopRace 3, StallWatchdog 12, Wedge 7, Stop 2, ConfigChange 10), rc 0. Wedge, Stop and ConfigChange suites are unedited.
- R2. 20 consecutive `swift test --parallel` runs of the whole audiotap target, each rc 0, 521 of 521 tests in every log, zero `error:` lines, the 3 stop-race tests and the timer test present in every log (/private/tmp/gh73-run-1.log to gh73-run-20.log). The 20 runs ran as two back-to-back foreground batches of 10 on the same tree, because one 600 s tool call does not fit 20 runs.
- Log check. `log show` showed the new lines at Default (notice) level with both reasons, "was stopped" and "gave up", and no device identifiers. The suites run for the check did not exercise the adoption-refused line. Only its level changed.
- Lint found 0 violations in 701 files and 0 files needing formatting. Line counts are MicCaptureHandler.swift 582, the StopRace tests 223, the StallWatchdog tests 585 and the RestartArbiter tests 326. `swift build` of app/MeetingTranscriber succeeded and compiled AudioTapLib.
- The commit message records the cause. The reproduction showed a production race, and runner load decided how often CI saw it.

Defect route:
- prior fixes: no open fork or upstream PR touches MicCaptureHandler or RestartArbiter, no reverts on those files, no matching memory bug entry, no other open fork issue for the symptom. The check ran after the fix was written (late against the route's order) and found nothing that would have changed it.
- diagnosis: eliminated "a timer tick after stop()" (stop() invalidates the timer, and the manual-clock test with no timer reproduces it); confirmed "an attempt queued on restartQueue before stop() builds its session after stop() returned" (task .1's held-queue reproduction failed on every run, and the guard turns it green).
- introduced by: skipped: no known-good revision (the build-first order dates from 603f6213, which moved restart attempts onto restartQueue)
- base: 4 failures `("2") is not equal to ("1")` at cd44d94e with the wrappers removed | head: 61 focused tests and 20 full-target runs green at 1f207e2a
- live: no live surface (library; the tests are the proof)

Follow-ups:
- The app-audio channel has the same shape. `AppAudioCapture.completeRestart` queues `performAttempt()` on its own restart queue, which builds an aggregate device and tap before it consults the arbiter, and `AppAudioCapture.stop()` does not wait on that queue. An app-tap restart queued before stop() would build a tap after stop() returned and then destroy it. This is outside this spec's Touches (microphone only), and nothing has measured it.

Decisions:
- One commit carries the guard and the wrapper removal, with no separate red commit. Task .1 already committed the reproduction, and a red commit would break bisection.
- The refusal reads the arbiter state once under its lock, so the reason it logs is the seal that refused the attempt, even if a give-up turns into a stop right after.
- A nil seal is unreachable for a launched attempt. It reads "a newer attempt took over".
- The review ran its normal three draws (correctness, contracts, integration) because the change adds a lock to production concurrency.

baseline: green (swift test --parallel --filter 'MicCaptureHandlerStallWatchdogTests|RestartArbiterTests|MicCaptureHandlerStopRaceTests', 38 tests, rc 0; lint 0 violations)
Tier: session (jev-unavailable(no_key)); actual model: claude-opus-5-5

stage: impl-review - ran [2026-10-08T14:10Z..2026-10-08T14:15Z] (codex gpt-5.6-sol xhigh, three draws, all SHIP, no findings)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 1f207e2ae967eb65a9b0a3926681a64368f72d67
- Tests: cd tools/audiotap && swift test --parallel --filter 'RestartArbiterTests|MicCaptureHandlerStopRaceTests|MicCaptureHandlerStallWatchdogTests|MicCaptureHandlerWedgeTests|MicCaptureHandlerStopTests|MicCaptureHandlerConfigChangeTests' (61 tests, rc 0), cd tools/audiotap && swift test --parallel, 20 consecutive runs (each rc 0, 521/521 tests), PATH=$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH ./scripts/lint.sh (0 violations, 701 files), cd app/MeetingTranscriber && swift build (rc 0)
- PRs: