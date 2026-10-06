---
satisfies: [R3, R7]
---
# gh-43-microphone-in-the-menu-and-the-meeting.1 Switch a running microphone capture to another device and report the device in use (AudioTapLib)

## Description
Capture library (`tools/audiotap`, AudioTapLib) only. Let a running microphone capture move to another device on request, through the existing claim-and-launch restart path, and report which device the capture is on. This is the early proof point: everything in the app builds on these two public calls. No app-target change in this task.

**Builds on spec gh-44.** This task starts from a `wapp/main` that already contains gh-44's code (its `MicPinSettle`, `MicConfigChangePolicy` and the new `MicCaptureHandler` config-change extension file). Read that code first; do not redo or move any of it. If gh-44 is not merged yet, stop and report (the spec dependency should prevent that).

**Size:** M
**Files:** `tools/audiotap/Sources/MicInputDevice.swift`, `tools/audiotap/Sources/MicEngineSession.swift`, `tools/audiotap/Sources/MicCaptureHandler.swift` (stored properties only), new `tools/audiotap/Sources/MicCaptureHandler+DeviceSelection.swift`, `tools/audiotap/Sources/MicCaptureHandler+Restart.swift`, `tools/audiotap/Sources/MicCaptureHandler+StallWatchdog.swift` (trigger enum), `tools/audiotap/Sources/AudioCaptureSession.swift`, new `tools/audiotap/Tests/MicCaptureHandlerDeviceSelectionTests.swift`, `docs/architecture-macos.md`
**Touches:** [tools/audiotap/Sources/MicInputDevice.swift, tools/audiotap/Sources/MicEngineSession.swift, tools/audiotap/Sources/MicCaptureHandler*.swift, tools/audiotap/Sources/AudioCaptureSession.swift, tools/audiotap/Tests/MicCaptureHandlerDeviceSelectionTests.swift, docs/architecture-macos.md]

### Approach
- **Tests first** (the contract is clear): write `MicCaptureHandlerDeviceSelectionTests` with fake sessions before the implementation, run them, see them fail for the stated reason. Copy the fake-session shape from `tools/audiotap/Tests/MicCaptureHandlerStallWatchdogTests.swift:23-140` (`StallTestSession` records `hardwareFormat(deviceUID:)` UIDs and can wedge/fail; `StallTestSessionQueue` hands out sessions in order) into the new file as private types; give the fake a settable `boundInputDevice` so adoption can be asserted. Build the handler through the internal test-seam `init(outputURL:…sessionFactory:decideRetry:stallWatchdogLimits:stallClock:isDevicePresent:)` (`MicCaptureHandler.swift:174-196`), plus gh-44's `configChangeLimits:` parameter if it exists.
- `MicInputDevice` (`MicInputDevice.swift:15-18` area): make the struct and both fields `public`, add a public memberwise `init`, and a `public static func systemDefaultInput() -> MicInputDevice?` built from the same two helpers `MicEngineSession` uses privately today (`MicEngineSession.swift:118-131`: `describe` and `systemDefaultInputDeviceID`). Move those helpers so both callers share one definition (e.g. `MicInputDevice.init(deviceID:)` + a static default-input lookup in `MicInputDevice.swift`); `MicEngineSession.boundInputDevice` keeps its behaviour.
- `MicRestartTrigger` (`MicCaptureHandler+StallWatchdog.swift:10-30`): add `case deviceSelected`, `logDescription` "device selection", `stallRestart` nil.
- Stored state in `MicCaptureHandler.swift` (583 lines, SwiftLint `--strict` caps files at 600): only the new stored properties, e.g. `public internal(set) var activeInputDevice: MicInputDevice?` and `var selectionPending = false`, both main-queue confined like `session`. Everything else goes in the new `+DeviceSelection.swift`.
- `activeInputDevice`: capture `session.boundInputDevice` inside `startEngine` right after `hardwareFormat` (`MicCaptureHandler.swift:231-248`, where the debug line already reads it; make the read unconditional and reuse it for that line) and carry it out with the rate (change the discardable return to a small struct, or an inout/out value) so that `start(deviceUID:)` sets it on main at the first start, and `runRestartAttempt` → `adopt` (`MicCaptureHandler+Restart.swift:100-178`) publishes it on main only when the arbiter says `.adopt`. Set it to nil in `stop()` and in both give-up paths (`handleAttemptTimeout` `:181-194`, `scheduleRestartRetry` `.giveUp` `:213-226`).
- `public func selectDevice(uid: String?)` in `+DeviceSelection.swift`: return when `uid == selectedDeviceUID`; else store it, then `claimRestartAttempt()` (`MicCaptureHandler+Restart.swift:42-57`). Granted → `stallWatchdog.withLock { _ = $0.restartLaunched(byStall: false) }` exactly as `handleDeviceChange` does (`:26-31`) and `launchRestartAttempt(…, trigger: .deviceSelected)`. Not granted and the session not sealed (`arbiter.withLock { $0.mayCreateOutputFile }` true and a capture was started) → `selectionPending = true` and log the deferral. Sealed → nothing.
- **Retry target (bug in today's code that a selection would hit):** `scheduleRestartRetry` launches with `currentRestartTarget() ?? deviceUID` (`MicCaptureHandler+Restart.swift:228-236`), so when the new choice resolves to nil (System Default, or a chosen UID that is not connected) the retry goes back to the previous, failing device. While `selectionPending` is set, the retry must use `currentRestartTarget()` as is (nil meaning the system default); without a pending selection keep today's expression unchanged. Test first: previous device's attempts keep failing, select System Default during the backoff, then the next attempt's `hardwareFormat(deviceUID:)` receives nil; same for a UID the injected `isDevicePresent` reports absent.
- In `adopt` (after `session = candidate`, arbiter now `.capturing`): if `selectionPending`, clear it, and when the adopted `deviceUID` differs from `currentRestartTarget()` (`:243-246`, make it internal if needed) claim one more restart with trigger `.deviceSelected`. Clear `selectionPending` on stop and give-up.
- Logs (logger category `MicCapture`, `.notice` so they are retained; no UID, no name): "Mic: microphone selection changed during the recording, restarting capture", "Mic: microphone selection changed while a restart is running, applying it after that restart", and on adopting a `.deviceSelected` restart "Mic: capture restarted on the newly selected microphone (<rate> Hz)" in place of the info-level "engine restarted" line for that trigger (same branching as stall restarts at `:167-172`).
- `AudioCaptureSession` (`AudioCaptureSession.swift:317-340`, next to `micLevelDBFS`): `public var micInputDevice: MicInputDevice? { micCapture?.activeInputDevice }`, `public func selectMicrophone(deviceUID: String?) { micCapture?.selectDevice(uid: deviceUID) }`, and `public var microphoneTrackActive: Bool` meaning a microphone capture exists and has not given up (`micCapture != nil && !micCaptureGaveUp`; `startMicCapture` (`:198-236`) sets `micCapture` to nil when the microphone fails to start and the session continues app-only). Main queue, like the rest of its public API. Cover `microphoneTrackActive` with the session's existing fake-session seam (`AudioCaptureSessionTracksTests` style): false without a mic URL, false after a failed mic start with an app track, true while capturing.

### Investigation targets
**Required** (read before coding):
- `tools/audiotap/Sources/MicCaptureHandler+Restart.swift` — claim, launch, attempt, adopt, timeout, retry; the whole selection rides on it
- `tools/audiotap/Sources/RestartArbiter.swift:116-195` — which phases grant `.deviceChanged`; do not change the transition table
- `tools/audiotap/Sources/MicCaptureHandler.swift:174-260` — test-seam init, `start`, `startEngine`
- `tools/audiotap/Tests/MicCaptureHandlerStallWatchdogTests.swift` — fake sessions and how tests wait for an adoption on the main queue
- gh-44's `MicCaptureHandler` config-change extension and its tests — adoption hooks it added

**Optional** (reference as needed):
- `tools/audiotap/Sources/MicEngineSession.swift:100-131` — `boundInputDevice`, `describe`, default-input lookup
- `tools/audiotap/Sources/MicDevicePinOutcome.swift` — why log lines carry no UID

### Key context
- `claimRestartAttempt` returns nil both when not capturing and when the arbiter is busy; tell "sealed" from "busy" with `arbiter.mayCreateOutputFile` (false only once stopped or given up) plus `isRecording`/phase, never by guessing.
- No test may construct a real `MicEngineSession` (reading `inputNode` on an input-less CI host raises an uncatchable NSException).
- A selection restart must not move the stall watchdog's stall-restart counters or gh-44's configuration-change window; assert both.
- Run: `cd tools/audiotap && swift test --parallel > /private/tmp/<dir>/audiotap.log 2>&1`, read the log (never pipe a test run into tail/head/grep). Lint: `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (`scripts/tool-versions.sh`; not installed globally: fetch the pinned release assets into a temp dir, verify the SHA-256, put them first on `PATH`).
- Do not edit `CLAUDE.md` / `AGENTS.md` (fork rule).
## Acceptance
- [ ] `MicCaptureHandler.selectDevice(uid:)` and `activeInputDevice`, `AudioCaptureSession.selectMicrophone(deviceUID:)`, `micInputDevice` and `microphoneTrackActive` (tested for no mic, failed mic start, running), and `MicInputDevice` (with `systemDefaultInput()`) are public; the restart arbiter's transition table is unchanged.
- [ ] Fake-session tests show: a selection while capturing launches exactly one attempt aimed at the new UID and publishes the new `activeInputDevice` on adoption; the current UID again launches nothing; a selection during an outstanding attempt leads to exactly one more attempt after that adoption, and the last of several selections is the one adopted; a selection during a backoff is used by the retry without an extra attempt, and choosing System Default or an unconnected UID during the backoff of a failing device makes the next attempt receive nil (not the previous UID); a selection after stop or give-up launches nothing; a selection of a UID that is not present targets the system default.
- [ ] A selection restart moves neither the stall watchdog's stall-restart counters nor gh-44's configuration-change window, asserted in a test.
- [ ] `activeInputDevice` is nil before start and after stop and after both give-up paths; the new log lines are notice level and contain no device UID or name (asserted where the wording is built).
- [ ] `MicCaptureHandler.swift` stays under 600 lines; `cd tools/audiotap && swift test --parallel` is green (log read from a file) and `./scripts/lint.sh` passes with the pinned tools.
- [ ] `docs/architecture-macos.md` has a row for `MicCaptureHandler+DeviceSelection.swift`.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
