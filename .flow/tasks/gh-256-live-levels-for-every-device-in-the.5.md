---
satisfies: [R2, R3, R4, R13]
---
# gh-256-live-levels-for-every-device-in-the.5 Visibility, pause, resume and the capture gate

## Description
When the meters may run, and the gate every recording start waits on: the window's visibility as an input, the pause signal (recording activity and the call signal), the ten-second resume, and the capture gate, wired into the recording side (spec Architecture, "The pause signal" and "The capture gate"; R2, R3, R4; A4, A5, A6, D9, A16).

**Size:** M
**Files:** `Sources/DeviceLevelMeters+RunState.swift` (new), `Sources/DeviceLevelMeters+CaptureGate.swift` (new), `Sources/WatchingController+DeviceMeters.swift` (new), `Sources/WatchingController+RecorderFactory.swift`, `Sources/WatchingController+LocalModel.swift`, `Tests/DeviceLevelMetersRunStateTests.swift` (new), `Tests/CaptureGateStartTests.swift` (new), `docs/architecture/recording.md`, `docs/architecture-macos.md` (rows for the new files)
**Touches:** [app/MeetingTranscriber/Sources/DeviceLevelMeters+RunState.swift, app/MeetingTranscriber/Sources/DeviceLevelMeters+CaptureGate.swift, app/MeetingTranscriber/Sources/WatchingController+DeviceMeters.swift, app/MeetingTranscriber/Sources/WatchingController+RecorderFactory.swift, app/MeetingTranscriber/Sources/WatchingController+LocalModel.swift, app/MeetingTranscriber/Sources/WatchingController.swift, app/MeetingTranscriber/Tests/DeviceLevelMetersRunStateTests.swift, app/MeetingTranscriber/Tests/CaptureGateStartTests.swift, docs/architecture/recording.md, docs/architecture-macos.md]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first, with an injected clock and .4's fake layer.
1. **Run state:** the set is active when the window is visible, the pause signal is off and ten seconds have passed since it last cleared. Pause on: recording activity, or the last call read listing a meeting; `pauseReason` is `recording` when both hold. Pause or not visible: move the generation on and close everything within one second (A5; A16, no grace period). A flap restarts the ten seconds. Becoming visible while paused opens nothing.
2. **Call signal** (A4): while the window is open, every three seconds, `signallingMeetings()` on a detector of the meters' own, built as `WatchingController.defaultDetector(settings:)` (`Sources/WatchingController+Detectors.swift:12`) so the watch loop's detector is never called from another thread. The read enumerates Core Audio processes, so it runs off the main actor with its own two-second deadline. Until a read has answered, and while one is overdue, count it as a call: opening a device during a call is the harm the pause exists to prevent. So a window opened during a call opens nothing before the first answer (spec Edge Cases, "The window opened during a call").
3. **Recording activity:** `recordingActivityChanged()` (`Sources/WatchingController+LocalModel.swift:52`) also pushes `isRecordingActivity` to the meters, in the same main-actor turn, as it already does for the permissions gate.
4. **Capture gate** (R3, A6): returns at once when nothing is open or outstanding (.4's `hasOpenOrOutstanding`); otherwise pauses with reason `recording` (the activity push usually did already), waits for every close and outstanding call, at most two seconds, then, when a closed meter was a Bluetooth input (`kAudioDeviceTransportTypeBluetooth` or `…BluetoothLE`), until 1.5 s after that close. Past the bound it logs one line and returns.
5. **Where the gate runs:** as the last await inside `makeRecorderFactory()`'s closure (`Sources/WatchingController+RecorderFactory.swift:16-33`), just before `return recorder`. Both production loops get that factory (`Sources/WatchingController+LoopFactory.swift:16`, `:49`), and its two call sites in `WatchLoop` are followed by the existing quit and cancellation checks (`Sources/WatchLoop.swift:334`, `:539`), so a quit or stop during the gate starts no recording, and `WatchLoop.swift` (600 lines, SwiftLint `--strict` cap) is not edited. This meets the spec's "one gate right before `recorder.start`" with the re-check after the whole wait.
6. **Docs:** `docs/architecture/recording.md` gets the gate and the meters' place in the start order, next to "Start order (issue #693)" (`:9`).

### Investigation targets
**Required** (read before coding):
- `Sources/WatchingController+RecorderFactory.swift` and `Sources/WatchingController+LoopFactory.swift` — the factory every production loop uses
- `Sources/WatchLoop.swift:306-345, 515-545` — the two start sites and their checks after the factory
- `Tests/QuitStartRefusalTests.swift:11-52` and `Tests/AsyncGate.swift:64` — parking a start inside the factory
- `Sources/WatchingController+LocalModel.swift:15-60` — `isRecordingActivity` and its push

**Optional** (reference as needed):
- `Sources/MicInputDetector.swift:300-345` — `signallingMeetings()` and its Core Audio reads
- `Sources/MeetingMicrophoneVerdict.swift:85-90` — transport type names

### Key context
- The detected path sets `.recording` and fires `onMeetingCapture(true)` before awaiting the factory; the manual path counts from its registration. The pause has usually closed the meters before the gate runs; the gate covers outstanding calls and the starts with no call signal (manual, microphone-only, `/v1/record`, Record Again).
- `WatchingController.swift` is at 585 lines; anything stored there must stay within the cap.

## Acceptance
- [ ] Run-state tests, written first and seen failing: each pause source closes everything within one second; meters return ten seconds after the signal cleared, and a flap restarts the wait; `recording` wins over `call`; not visible closes within one second; becoming visible while paused opens nothing; a window opened during a call opens nothing before the first call read answers; an overdue call read counts as a call.
- [ ] Gate tests: it returns at once with nothing open or outstanding; it waits for an outstanding close; an open stalled before its start step and released after the gate began starts no device; it gives up at two seconds with one log line; after closing a Bluetooth input it waits until 1.5 s after that close.
- [ ] Start tests: the manual, microphone-only, detected and Record Again starts, each parked inside the gate and then quit or stopped, start no recording (the `QuitStartRefusalTests` pattern through the production factory with an injected recorder).
- [ ] `docs/architecture/recording.md` states the gate and its place in the start order.
- [ ] Quick commands green; `./scripts/lint.sh` clean with the pinned tools.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
