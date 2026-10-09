# No microphone restart after the capture has stopped (flaky watchdog timer test)

## Conversation Evidence

> issue #73 (filed 2026-10-06): "Der Test `AudioTapLibTests.MicCaptureHandlerStallWatchdogTests.testTheTimerDrivesTheWatchdogAndStopsWithTheCapture` (kam mit dem Mikrofon-Watchdog-Fix aus #44) ist im Fork-CI auf PR #71 in **beiden Versuchen** eines Laufs fehlgeschlagen … `fixture.sessions.count` hat sich **nach** `handler.stop()` noch erhöht (\"no attempt after the stop\"). … Lokal läuft der Test einzeln 8 von 8 Mal grün"
> issue #73, Wunsch: "Klären, welches von beiden; bei einem Rennen `stop()` so machen, dass ein laufender Neustart nichts mehr übernimmt, sonst den Test auf eine injizierte Uhr umstellen."
> issue #73, Abnahme: "Test läuft unter `swift test --parallel` wiederholt (z. B. 20×) grün; CI-Läufe auf Code-PRs scheitern nicht mehr daran."
> user (2026-10-07, selected): "A — Spec #60 + #73 now (Recommended)"

## Goal & Context

The microphone stall watchdog restarts a capture that stops delivering audio. Its timer-driven test failed twice in one CI run: after the capture was stopped, one more capture session was still created. It passes when run alone. Either the watchdog can start or adopt a restart after `stop()` (a real defect: the microphone would be reopened after the person or the app stopped recording) or the test's real-clock timing is too tight under CI load. The flake also turns unrelated pull requests red, which costs reruns and can park unattended loop runs. [paraphrase]

**What a planning probe measured (2026-10-07, on gh-44's finished branch).** A restart attempt is claimed, charged and handed to the serial restart queue on the main queue, and the attempt's first step on the restart queue is to build its session, before it consults the restart arbiter at all. `stop()` seals the arbiter and returns without waiting for the restart queue, because an attempt there can wedge forever (upstream issue #588). An attempt that was queued but had not started when `stop()` ran therefore still builds a session after `stop()` returned, binds and starts the microphone on it, and only then learns from the arbiter that the capture is sealed; it tears the session down without adopting it and logs, at info level (not retained), that it "outlived its deadline". A throwaway test that held the restart queue with a blocking item while a stall restart was claimed, called `stop()`, then released the queue, failed every time with `("2") is not equal to ("1")`, the same assertion CI reported. The timer test waits only until the restart is charged, which happens before the queued attempt builds its session, so on a loaded runner the attempt starts after `stop()`. The cause is a production race that the test's timing exposes; the task that reproduces it records this. [inferred]

<!-- Source: 35% user / 25% [paraphrase] / 40% [inferred] -->

## Architecture & Data Models

All changes live in AudioTapLib (`tools/audiotap`): the restart arbiter gains one read-only question, the capture handler orders its stop against the building of a restart session, and two tests force the race on every run. No app-target, settings or UI change.

- **Restart arbiter.** A pure query that says whether the attempt with a given generation may still build its session: true only while that generation is the attempt in flight; false once the capture was stopped or given up, and for a superseded generation. A second read-only answer says which seal holds (stopped, given up, or none), so both log lines below take their reason from one place. No phase or transition changes.
- **Building a restart session.** The attempt asks that question and builds its session inside one critical section that `stop()`'s seal also takes, so the two are totally ordered: either the attempt builds first and `stop()` finds an attempt in flight (unchanged behaviour), or `stop()` seals first and the attempt builds nothing. The lock that orders them is a dedicated one, held only for the seal and for the check-and-build; lock order is that lock, then the arbiter's, never the reverse. The arbiter's own lock is never held across the session factory.
- **What every trigger shares.** Stall, default-input-change and configuration-change restarts, and the retries of a failed attempt, all build their session through this one attempt path, so the guard covers each of them without a per-trigger change. A device-selection trigger planned elsewhere (gh-43) uses the same claim-and-launch path and is covered the same way.
- **Logs.** An attempt refused before building logs one line saying why (stopped or given up, from the arbiter's seal answer). The existing line for an attempt that returns after the seal names the actual reason instead of always "outlived its deadline". Both lines and the adoption-refused line are notice level, public, and carry no device UID or name.

## Edge Cases & Constraints

- This is a defect: the cause is the unknown. Reproduce it first (repeated parallel runs, or a deterministic schedule that forces a restart to be in flight when `stop()` is called), then fix the cause that the reproduction shows. [paraphrase]
- The same code is changed by the stall-restart work (gh-44); this spec builds on that work. gh-44 is finished on its branch (all three tasks and its completion review done) but not merged; it adds the configuration-change pacing (a delayed restart that `stop()` cancels) and a Bool return on the device-change entry, and edits `stop()`, adoption and the give-up paths, while leaving the attempt's build order (the race) unchanged. Where a later gh-44 change would alter this plan: a moved or reworded `runRestartAttempt`, `stop()` or adoption (line references shift, the guard's placement does not), a new path that builds a session outside the attempt (it would need the same guard), or a change to the stall watchdog test fixture (task .1 and .2 edit that file). [inferred]
- An attempt that already built its session before `stop()` sealed the arbiter continues: it may bind and start the microphone after `stop()` returned, then it is refused, torn down on the restart queue and logged (R1's error clause). Existing tests already pin that it is never adopted. Preventing that bring-up as well would need a seal check before each engine call; it is out of scope.
- A retry waiting out its backoff when `stop()` runs is already refused by the arbiter (the retry-due event is ignored once stopped); it stays refused.
- The attempt's 5 s deadline fires after `stop()` and is ignored by the arbiter; it never reports a give-up for a stopped capture.
- A handler released while an attempt is queued: the queued attempt holds the handler weakly and does nothing.
- The session factory runs while the dedicated lock is held, so it must never call back into the handler; the production factory only allocates an `AVAudioEngine`.

## Acceptance Criteria

- **R1:** Once the microphone capture's `stop()` has returned, the stall watchdog creates and adopts no new capture session, including a restart that was already in flight when `stop()` was called. Errors: a restart that completes after the stop is torn down without being adopted, and that is logged. [paraphrase]
- **R2:** The timer-driven watchdog test is deterministic: it passes 20 consecutive runs under parallel execution of the audio-capture test target, and it fails when the R1 guard is removed. Errors: no error surface beyond the test result. [paraphrase]
- **R3:** The change records which cause the reproduction showed (production race, test timing, or both) in its commit message. Errors: no error surface.

## Early proof point

Task gh-73-no-microphone-restart-after-the-capture.1 validates the core approach (a stall restart that was claimed and queued before `stop()` builds a session after `stop()` returned, reproduced on every run by holding the serial restart queue). If it fails, re-evaluate the cause (a timer tick after `stop()`, or the test's own counting) before continuing with gh-73-no-microphone-restart-after-the-capture.2.

## Boundaries

- No change to when or how often the watchdog restarts a stalled microphone during a recording; only behaviour after stop and the test's determinism are in scope.
- No test is weakened, skipped or deleted to get green. [paraphrase]
- No change to the restart arbiter's phases or transitions, the retry policy, the attempt deadline, the stall watchdog's limits, or gh-44's configuration-change pacing.
- Stopping a session that was built before `stop()` from being brought up afterwards (a seal check before every engine call) is out; follow-up only if the owner wants no microphone access at all after stop.
- Moving the outgoing engine's teardown off the main thread is upstream issue #55, not this spec.

## Decision Context

- **A1 · Build after gh-44 lands, not alongside it.** flip at: gh-44 is abandoned or merged · test: the spec's dependency on gh-44 · status: active [agent-inferred 2026-10-07]
- **A2 · Guard the build, not every engine call: the attempt checks the seal and builds its session in one critical section that stop()'s seal also takes; an attempt already past that point is brought up, refused on return and torn down.** flip at: the guard at the start of the restart attempt · test: the queued-across-stop tests (task .1, .2) and the existing wedged-attempt-after-stop tests · alternatives: stop() waits for the restart queue (rejected: an attempt can wedge forever, upstream #588); a check without a shared critical section (rejected: leaves a window between the check and the build) · status: active [agent-inferred 2026-10-07]
- **A3 · A dedicated lock, held only by stop()'s seal and the attempt's check-and-build, orders them; the arbiter's lock is never held across the session factory.** flip at: the build lock on the capture handler · test: the deterministic queued-across-stop test plus review of lock order · alternatives: hold the arbiter's lock across the factory (rejected: the render thread reads that lock for every buffer and an unfair lock aborts on re-entry) · status: active [agent-inferred 2026-10-07]
- **A4 · Reproduce with a deterministic schedule (a blocking item on the serial restart queue) and keep the timer test on its real timer with the same hold, rather than switching it to an injected clock.** flip at: the two queued-across-stop tests · test: they fail with the guard removed and pass 20 times in a row under parallel runs with it · alternatives: an injected clock (the issue's fallback, rejected: the cause is the race, which a clock would hide) · status: active [agent-inferred 2026-10-07]
- **A5 · The reason a sealed attempt gives (stopped or given up) comes from one read-only answer on the restart arbiter, used by both the refused-before-build line and the late-return line; new tests go into their own test file because the stall watchdog test file is at 577 of SwiftLint's 600-line limit.** flip at: the arbiter's seal answer and the new stop-race test file · test: the arbiter's tests for that answer; `./scripts/lint.sh` clean · why: Maintainability (plan review): duplication - stopped/gave-up reason selection appears in both pre-build refusal and late-return logging; structure - none identified · status: active [agent-inferred 2026-10-07]

Maintainability (plan review, round 2): duplication - task .1 mirrors the private clock, session and factory test fakes in the new stop-race suite (advisory; the same copy gh-44 made, kept to avoid refactoring the stall watchdog test file); structure - none identified

FIT: GO · 2026-10-08 · base ed0b4e6d · engine flow-next 8.1.1 · gh-44 merged into wapp/main on 2026-10-07 (PR #75), so A1 holds; tools/audiotap on the base is byte-identical to gh-44's planning head 6e259686, every task anchor matches by symbol; no spec or doc changed since the plan review claims the microphone restart path (gh-94 is the watch loop, the doc commits cover other features)

## Memory findings

| Track | Category | Entry | Why relevant |
| --- | --- | --- | --- |
| knowledge | workflow | run-swift-tests-locally-redirect-models-2026-10-06 | redirect test output to a log file and read it; never pipe a run into tail or grep |
| knowledge | workflow | lint-locally-with-the-cached-pinned-2026-10-06 | `./scripts/lint.sh` needs the cached pinned SwiftFormat and SwiftLint on PATH |

## Quick commands

```bash
cd tools/audiotap && swift test --parallel --filter 'MicCaptureHandlerStallWatchdogTests|RestartArbiterTests' > /private/tmp/gh73-audiotap.log 2>&1; echo "exit $?"
```

```bash
cd tools/audiotap && for i in $(seq 1 20); do swift test --parallel > /private/tmp/gh73-run-$i.log 2>&1 || echo "run $i FAILED"; done
```

## Requirement coverage

| Req | Description | Task(s) | Gap justification |
| --- | --- | --- | --- |
| R1 | Once the microphone capture's `stop()` has returned, the stall watchdog creates and adopts no new capture session, including a restart that was already in flight when `stop()` was called. Errors: a restart that completes after the stop is torn down without being adopted, and that is logged. | gh-73-no-microphone-restart-after-the-capture.2 | — |
| R2 | The timer-driven watchdog test is deterministic: it passes 20 consecutive runs under parallel execution of the audio-capture test target, and it fails when the R1 guard is removed. Errors: no error surface beyond the test result. | gh-73-no-microphone-restart-after-the-capture.1, gh-73-no-microphone-restart-after-the-capture.2 | — |
| R3 | The change records which cause the reproduction showed (production race, test timing, or both) in its commit message. Errors: no error surface. | gh-73-no-microphone-restart-after-the-capture.2 | — |

