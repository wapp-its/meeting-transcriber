---
satisfies: [R2, R3, R5]
---
# gh-44-stop-the-microphone-restart-loop-on-a.2 Decide when a configuration change may restart the microphone

## Description
The pure decision behind configuration-change restarts: when a notification may restart the microphone at once, after a backoff, or not at all, and which of those decisions are logged (spec R2, R3's bound, R5's wording). No wiring here; task .3 connects it to the handler. Split out so every boundary is tested without an engine, exactly as `MicStallWatchdogPolicy` was for PR #57.

**Size:** M
**Files:** `tools/audiotap/Sources/MicConfigChangePolicy.swift` (new), `tools/audiotap/Tests/MicConfigChangePolicyTests.swift` (new)
**Touches:** [tools/audiotap/Sources/MicConfigChangePolicy.swift, tools/audiotap/Tests/MicConfigChangePolicyTests.swift]

### Approach
- Tests first (`MicConfigChangePolicyTests`, style of `MicStallWatchdogPolicyTests.swift:1-60`), see them fail, then implement.
- Follow `MicStallWatchdogPolicy` (`MicStallWatchdogPolicy.swift:71-140`): `struct MicConfigChangePolicy: Equatable`, nested `struct Limits: Equatable, Sendable` with `static let production`, a `Decision` enum, `mutating` methods taking monotonic seconds from the caller, and a type doc comment that states the incident (233 starts in 35 s, watchdog starved), the rule, and the worst case.
- Contract (signatures only; names may be polished, semantics may not):
  - `Limits(windowSeconds: TimeInterval, maxRestartsPerWindow: Int, backoffSeconds: [TimeInterval])`; `.production = (60, 3, [0, 1, 2])`.
  - `mutating func engineStarted(at now: TimeInterval)` and `func secondsSinceEngineStart(at now: TimeInterval) -> TimeInterval?` (for the log line).
  - `mutating func decide(at now: TimeInterval, restartPending: Bool) -> Decision` with `Decision`: `.restart(afterSeconds: TimeInterval)`, `.ignore(IgnoreReason, log: Bool)` and `IgnoreReason`: `.restartPending`, `.capReached`.
  - `mutating func restartLaunched(at now: TimeInterval)` — the only thing that charges the budget; the caller calls it only when the arbiter granted the attempt.
- Rules: launches older than `windowSeconds` drop out (a launch at `t` counts while `now - t < windowSeconds`). `restartPending` wins first (`.ignore(.restartPending)`), then the cap (`k >= maxRestartsPerWindow` → `.ignore(.capReached)`), else `.restart(afterSeconds: backoffSeconds[min(k, count - 1)])` where `k` is the launches in the window. `log` is true for the first ignore of each reason and then again only once `windowSeconds` passed since that reason was last logged.
- Pure log-line helpers on the type (so the wording is under test, like `MicDevicePinOutcome.logLine`), no UID or device name anywhere: a restart decision, rendered when the notification arrives ("Mic: engine configuration changed <s> s after the engine started; restarting now|in <d> s (<k> configuration-change restarts already launched in the last <window> s, at most <cap>)"), where `<k>` is the count before this one, so the line never claims a launch the arbiter may still decline, the pending ignore, and the cap ignore, which must say the stall watchdog stays armed ("…; not restarting on configuration changes until the window frees a slot, the stall watchdog stays armed"). "After the engine started" renders "?" when no start was recorded.

### Investigation targets
**Required** (read before coding):
- `tools/audiotap/Sources/MicStallWatchdogPolicy.swift:1-245` — the pattern to mirror, including the clock note (`:142-149`)
- `tools/audiotap/Tests/MicStallWatchdogPolicyTests.swift` — test layout and the "production limits are the documented ones" test

**Optional** (reference as needed):
- `tools/audiotap/Sources/CaptureRestartRetryPolicy.swift` — backoff schedule style
- `tools/audiotap/Sources/RestartArbiter.swift:28-108` — why only granted launches may be charged

### Key context
- The policy never sees the arbiter, the session or the device: it is main-queue state in task .3, so it needs no lock and must stay a value type.
- A decision is not a launch: `.restart` must not charge anything by itself (the arbiter may decline), which is why `restartLaunched(at:)` is separate. Test that a `.restart` followed by no `restartLaunched` leaves the budget untouched.
- Tests to include: production limits equal (60, 3, [0, 1, 2]); first decision `.restart(0)`; after 1 and 2 launches `.restart(1)` and `.restart(2)`; after 3 launches inside 60 s `.ignore(.capReached, log: true)` then `log: false` on the next; at `first launch + 60` a slot is free again; `restartPending: true` → `.ignore(.restartPending, …)` without charging; logging resets after a window; `secondsSinceEngineStart` nil before `engineStarted`; exact wording of each line, with no UID-like text.
- Verify: `cd tools/audiotap && CFFIXED_USER_HOME=/private/tmp/gh44-home swift test --parallel --filter MicConfigChangePolicyTests > /private/tmp/gh44-t2.log 2>&1` and read the log; `./scripts/lint.sh` with the pinned SwiftFormat/SwiftLint (`scripts/tool-versions.sh`).
## Acceptance
- [ ] `MicConfigChangePolicyTests` exist, failed before the type existed, and pass for every rule listed in the task (immediate first restart, 1 s and 2 s backoff, cap of 3 per sliding 60 s, slot freed at the window edge, pending coalescing, no charge without `restartLaunched`, once-per-window logging of ignores, production limits).
- [ ] The log-line helpers produce the exact wording under test; the cap line says the stall watchdog stays armed; no line contains a device UID or name.
- [ ] `MicConfigChangePolicy` is a pure value type with no dependency on the arbiter, the session or CoreAudio, and its doc comment states the incident, the rule and the worst case.
- [ ] `./scripts/lint.sh` clean with the pinned tools.
## Done summary
Task .3 can now pace and cap microphone restarts on configuration changes with a tested decision type. The new value type is `MicConfigChangePolicy` (`tools/audiotap/Sources/MicConfigChangePolicy.swift`). It allows at most 3 configuration-change restarts in any 60 s window. The first restarts at once, the second after 1 s and the third after 2 s. A change while a delayed restart is pending adds nothing, and beyond the cap nothing is launched until the oldest launch leaves the window. Only `restartLaunched(at:)` charges the budget, and the caller calls it for arbiter-granted attempts only. Decisions that launch nothing are logged once per reason per window. The cap line says the stall watchdog stays armed. No line carries a device UID or name. The type has no dependency on the arbiter, the session or CoreAudio, and nothing calls it yet. Task .3 wires it into `MicCaptureHandler`.

Tests (`tools/audiotap/Tests/MicConfigChangePolicyTests.swift`, 15 cases) cover every rule the task lists:
- production limits are (60, 3, [0, 1, 2]) - `testTheProductionLimitsAreTheDocumentedOnes`
- immediate first restart - `testTheFirstChangeRestartsAtOnce`
- 1 s and 2 s backoff - `testTheSecondAndThirdRestartWaitOneAndTwoSeconds`
- the schedule clamps to its last entry - `testABackoffPastTheScheduleKeepsItsLastDelay`
- cap of 3, logged once - `testAFourthChangeInsideTheWindowLaunchesNothingAndIsLoggedOnce`
- a slot frees exactly at first launch + 60 s - `testTheWindowFreesASlotExactlyWindowSecondsAfterTheFirstLaunch`
- no charge without `restartLaunched` - `testADecisionThatIsNotLaunchedChargesNothing`
- pending changes coalesce - `testAChangeWhileARestartIsPendingAddsNothing`, `testAPendingRestartIsReportedBeforeTheCap`
- each ignore reason is logged once per window - `testEachIgnoreReasonIsLoggedAgainOnceAWindowPassed`, `testTheTwoIgnoreReasonsAreLoggedIndependently`
- seconds since the engine started is nil before any start - `testTheEngineStartIsUnknownUntilRecorded`
- exact wording of every line - `testTheLogLinesSayWhatWasDecided`, `testTheRestartLineCountsOnlyLaunchesInsideTheWindow`
- no device-identifying text - `testNoLineCarriesDeviceIdentifyingText`

Measured results:
- baseline: green via handoff (conductor baseline at b4fa8059: `cd tools/audiotap && swift test --parallel --filter 'MicPinSettleTests|MicConfigChangePolicyTests|MicCaptureHandlerConfigChangeTests|MicCaptureHandlerStallWatchdogTests'`, exit 0). The lint baseline ran here and was clean.
- Red run before the type existed: `swift test --parallel --filter MicConfigChangePolicyTests` exited 1 with "cannot find type 'MicConfigChangePolicy' in scope".
- Green run on the committed files: the same command exited 0 with 15/15 tests (log /private/tmp/gh44-t2.log).
- Lint with SwiftFormat 0.63.0 and SwiftLint 0.65.1: `./scripts/lint.sh` exited 0 with 0 violations (log /private/tmp/gh44-t2-lint.log).

Decisions:
- I polished the restart-line wording from the task template's "(<k> configuration-change restarts already launched in the last <window> s, at most <cap>)" to "(<k> of at most <cap> configuration-change restarts already launched in the last <window> s)". The new form avoids "1 restarts", and it carries the same count, cap and window. The cap line reuses that phrase and ends with the template's "; not restarting on configuration changes until the window frees a slot, the stall watchdog stays armed".
- `<s>` renders as "%.2f", because the self-caused change lands 50 to 100 ms after start and "%.1f" would round that away. Configured durations render as "%g" (60, 1, 0.05).
- I added the non-mutating `launchedInWindow(at:)`. `logLine` uses it, and task .3 can use it to assert "charges nothing" without the mutation `decide` makes.
- `logLine` reads `<k>` from current state. Task .3 must render the line before it calls `restartLaunched(at:)` for an immediate restart. The run notes record this in `t2-policy-api.md`.
- The test file and the type land in one commit. A test-only commit would not compile, which breaks the whole audiotap test target at that commit. The red run above is the proof the test failed first.

Not run: the full audiotap suite and the app build. This task adds a standalone type that nothing references yet. Task .3's verify step runs both.

stage: impl-review - ran [2026-10-06T21:54Z..2026-10-06T21:59Z] SHIP, one correctness reviewer, no surviving findings (model: codex gpt-5.6-sol xhigh)

Tier: session (jev-unavailable(no_key))

Integrated onto fix/gh-44-mic-restart-loop as 8de13e7c (cherry-pick of 1db334b1; identical tree). Integrated verify: cd tools/audiotap && swift test --parallel --filter MicConfigChangePolicyTests|MicPinSettleTests (exit 0; /private/tmp/gh44-int2.log).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 8de13e7c868897615e303728fbb69fe0b4ace8a1
- Tests: cd tools/audiotap && CFFIXED_USER_HOME=/private/tmp/gh44-home swift test --parallel --filter 'MicConfigChangePolicyTests|MicPinSettleTests' (25 tests, exit 0), PATH=/private/tmp/gh44-lint-tools/bin:$PATH ./scripts/lint.sh (exit 0, 0 violations; worker run on the same tree)
- PRs: