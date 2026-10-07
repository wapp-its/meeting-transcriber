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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
