---
satisfies: [R1, R5]
---
# gh-44-stop-the-microphone-restart-loop-on-a.1 Absorb the pinned microphone's own configuration change before the engine starts

## Description
Spend the configuration change that pinning the microphone causes before the engine starts (spec R1, settle half of R5). This is the fix aimed at the root cause in the spec's Goal & Context and the plan's early proof point; tasks .2 and .3 are the safety net that holds even if it does not help on the real headset.

**Size:** M
**Files:** `tools/audiotap/Sources/MicPinSettle.swift` (new), `tools/audiotap/Sources/MicEngineSession.swift`, `tools/audiotap/Tests/MicPinSettleTests.swift` (new)
**Touches:** [tools/audiotap/Sources/MicPinSettle.swift, tools/audiotap/Sources/MicEngineSession.swift, tools/audiotap/Tests/MicPinSettleTests.swift]

### Approach
- Write `MicPinSettleTests` first and see them fail (the type does not exist yet), then implement.
- `MicPinSettle` is a caseless `enum` namespace (SwiftLint `convenience_type`), file name = type name (`file_name` rule). Shape, signatures only:
  - `enum Outcome: Equatable, Sendable { case notNeeded; case settled(afterSeconds: TimeInterval); case timedOut(afterSeconds: TimeInterval) }` with `var logLine: String?` (nil for `notNeeded`).
  - `static let timeoutSeconds: TimeInterval = 0.5`
  - `static func run(observing object: AnyObject, center: NotificationCenter = .default, timeout: TimeInterval = timeoutSeconds, clock: () -> TimeInterval = MicStallWatchdogPolicy.monotonicNow, pin: () -> Bool) -> Outcome`. `pin` returns whether it moved the unit (a change is expected).
- Order inside `run` is load-bearing: register the observer (`forName: .AVAudioEngineConfigurationChange, object: object, queue: nil`, block only signals a `DispatchSemaphore`) BEFORE calling `pin()`, so a notification posted synchronously inside the set, or within microseconds after it, is not missed. Remove the observer on every path (`defer`); keep the token in a local so `discarded_notification_center_observer` is satisfied. When `pin()` returns false, return `.notNeeded` without waiting.
- Wiring in `MicEngineSession.hardwareFormat(deviceUID:)` (`MicEngineSession.swift:136-160`): run the existing `pin(deviceUID:on:)` (`:166-181`) inside `MicPinSettle.run(observing: engine) { … }`. "Moved" means: a UID was given and resolved, `AudioUnitSetProperty` returned `noErr`, and the unit's device read with `currentDeviceID(of:)` (`:185-197`) BEFORE the set differs from the requested id. Keep `pinOutcome` and its log line exactly as today (`:145-157`), then log `outcome.logLine` at `.notice` with `privacy: .public` (category `MicEngineSession`). The format read (`inputNode.outputFormat(forBus: 0)`) stays where it is, after the settle.
- Log wording, follow the pure-function pattern of `MicDevicePinOutcome.logLine` (`MicDevicePinOutcome.swift:104-133`): settled → "Mic: the configured microphone's configuration change arrived <N> ms after binding it and was absorbed before the engine started"; timed out → "Mic: no configuration change within 500 ms of binding the configured microphone; starting the engine anyway". No UID, no device name (the line is unconditional; see the "No device UID in here" note at `MicDevicePinOutcome.swift:104-111`). Render the timeout from `timeoutSeconds`, not a literal.
- Update the doc comment of `MicEngineSessionProviding.hardwareFormat` (`MicEngineSession.swift:40-44`) to say a pinned start may wait up to `MicPinSettle.timeoutSeconds` for the pin's own configuration change, and why (one or two sentences; cite the AVFAudio header rule in the spec's Resolved via Research).

### Investigation targets
**Required** (read before coding):
- `tools/audiotap/Sources/MicEngineSession.swift:1-262` — the session, its pin, and why no test may construct it (`:32-35`)
- `tools/audiotap/Sources/MicDevicePinOutcome.swift:1-133` — outcome/log-line pattern and the UID rule
- `tools/audiotap/Sources/MicCaptureHandler.swift:202-209,229-357` — where `hardwareFormat` is called (main queue at first start, restart queue in an attempt)

**Optional** (reference as needed):
- `tools/audiotap/Tests/MicDeviceDiagnosticsTests.swift` — test style for log lines
- `tools/audiotap/Sources/RestartArbiter.swift:28-34` — the 5 s attempt deadline the wait must stay well inside

### Key context
- Never construct `MicEngineSession` (or touch `AVAudioEngine.inputNode`) in a test: the CI runner has no input device and that raises an uncatchable NSException. Everything testable lives in `MicPinSettle`; the wiring is covered by the owner's headset check.
- The observer block runs on AVFAudio's private queue. Do nothing there but signal: the AVFAudio header warns the engine must not be torn down from inside the handler (deadlock).
- At a recording's first start this runs on the main queue, so the wait blocks main for at most 0.5 s (typically ~100 ms) and only for a pinned device. That is accepted in the spec; do not add a second wait or a retry loop.
- Use a private `NotificationCenter()` in the tests, never `.default`, so parallel test workers cannot cross-talk. To prove the observer is removed, a small `NotificationCenter` subclass that records `removeObserver(_:)` calls is enough.
- Tests (all in `MicPinSettleTests`): settled when another queue posts for the observed object after ~50 ms; timedOut (short timeout, e.g. 0.05 s) when nothing is posted; a post for a different object is ignored (timedOut); a post made synchronously inside the `pin` closure counts as settled; `pin` returning false yields `notNeeded` and returns well before a long timeout (e.g. 5 s); the observer is removed on settled, timedOut and notNeeded; exact `logLine` wording for each case, and none contains a UID-like string passed in by the test.
- Verify: `cd tools/audiotap && CFFIXED_USER_HOME=/private/tmp/gh44-home swift test --parallel --filter 'MicPinSettleTests|MicEngineSessionSeamTests|MicDeviceDiagnosticsTests' > /private/tmp/gh44-t1.log 2>&1`, read the log (never pipe into tail/grep); then the full audiotap suite once (`swift test --parallel > /private/tmp/gh44-t1-full.log 2>&1`). Lint: `./scripts/lint.sh` with SwiftFormat 0.63.0 / SwiftLint 0.65.1 per `scripts/tool-versions.sh` (fetch the pinned binaries into a temp dir and put it first on PATH if they are not installed; do not brew-install).

## Acceptance
- [ ] `MicPinSettleTests` exist, failed before `MicPinSettle` existed, and pass: settled, timed out, wrong object ignored, synchronous post counted, `notNeeded` returns without waiting, observer removed on every path, exact log wording without UID.
- [ ] `MicEngineSession.hardwareFormat` runs the pin inside `MicPinSettle.run(observing: engine)`, waits only when the pin moved the unit (noErr and a different device before the set), reads the format after the settle, and logs the outcome at notice level; the existing pin-outcome line is unchanged.
- [ ] Unpinned and unresolved-UID starts never wait (by construction: `pin` returns false or is not reached), stated in the code comment.
- [ ] `MicEngineSessionSeamTests`, `MicDeviceDiagnosticsTests` and the full audiotap suite pass (log files read, exit 0); `./scripts/lint.sh` clean with the pinned tools.


## Done summary
A pinned microphone's engine start now waits up to 0.5 s for the configuration change that the pin itself causes, so that change lands on an engine that has not started yet and never reaches the restart path. The new `MicPinSettle` registers a one-shot observer on the session's engine before the pin runs, waits only when the set returned `noErr` and the unit was on another device before it, and logs the outcome at notice level without any device identifier. `MicEngineSession.hardwareFormat` runs the existing pin inside it, keeps the pin-outcome line unchanged and still reads the format after the settle.

- Tests: `tools/audiotap/Tests/MicPinSettleTests.swift` has 10 tests. They cover a change posted from another queue (settled), no change (timedOut), a change for another object (ignored), a change posted inside the pin (settled), and a pin that did not move the unit (`notNeeded`, returns well under a 5 s timeout). They also cover the injected clock, observer removal on all three paths (by recorded tokens and a later post that reaches nothing), the `pinMovedUnit` rule table (nothing pinned, unresolvable UID, refused, already on the device, moved, unreadable before-device), the exact log wording, and that no line carries the UID given to the pin.
- Red run before implementation: build failed with `cannot find 'MicPinSettle' in scope` (`/private/tmp/gh44-t1-red.log`). A mutation check that registered the observer after the pin failed `testAChangePostedInsideThePinCounts`, `testTheDurationComesFromTheInjectedClock` and `testTheObserverIsRemovedOnEveryPath` (`/private/tmp/gh44-t1-mutant.log`). The code was then restored.
- baseline: green via handoff (conductor baseline at b4fa8059, `MicPinSettleTests|MicConfigChangePolicyTests|MicCaptureHandlerConfigChangeTests|MicCaptureHandlerStallWatchdogTests`, exit 0). No path outside `.flow/` had changed since then.
- The full audiotap suite (491 tests, exit 0) ran once before the lint fixes. Those fixes touched only the test file's style, one blank line between switch cases and one comment. The focused suites, the spec's Quick command, a release build and lint all re-ran green afterwards. The Quick command and lint ran on the commit.
- Decision: a unit whose device could not be read before the set counts as moved. Waiting then costs at most 0.5 s, while a missed change stops the engine.
- Not verified here: no test may construct `MicEngineSession`, so whether the settle makes the pinned Jabra deliver is still the owner's headset check from the spec's Verification section.
- No feature-map route changed.

Tier: session (jev-unavailable(no_key))

stage: impl-review - ran [2026-10-06T21:43Z..2026-10-06T21:51Z] SHIP, 3-lens panel, no findings (model: codex gpt-5.6-sol xhigh)

Integrated onto fix/gh-44-mic-restart-loop as 2f1e12bd (cherry-pick of 02aeb262; identical tree). Integrated verify: cd tools/audiotap && swift test --parallel --filter MicPinSettleTests|MicEngineSessionSeamTests|MicDeviceDiagnosticsTests|MicCaptureHandlerStallWatchdogTests (45 tests, exit 0; /private/tmp/gh44-int1.log).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 2f1e12bd30560ed3e96eb9e1d684439f725908a6
- Tests: cd tools/audiotap && CFFIXED_USER_HOME=/private/tmp/gh44-home swift test --parallel --filter 'MicPinSettleTests|MicEngineSessionSeamTests|MicDeviceDiagnosticsTests|MicCaptureHandlerStallWatchdogTests' (45 tests, exit 0), PATH=/private/tmp/gh44-lint-tools/bin:$PATH ./scripts/lint.sh (exit 0, 0 violations; worker run on the same tree), cd tools/audiotap && swift test --parallel (full audiotap suite, 491 tests, exit 0; worker run on the same tree)
- PRs: