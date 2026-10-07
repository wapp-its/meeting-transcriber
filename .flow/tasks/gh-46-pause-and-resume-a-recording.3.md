---
satisfies: [R2, R7]
---
# gh-46-pause-and-resume-a-recording.3 Recorder pause and channel-health hold

## Description
The app side of the capture pause, below the watch loop: the recorder protocols gain pause/resume/isPaused, `DualSourceRecorder` forwards them to the capture session, passes the session's pause positions out with the recording, and keeps a paused recording looking alive to the staging recovery; the channel-health polling holds its checks while the recorder is paused (spec: Architecture "The pause state lives in WatchLoop" (recorder mirror), "Alignment and positions", "Channel health is held while paused"; Edge Cases "Staging recovery"; R7). Needs task 1's public session API. Touches no `WatchLoop` code, so it does not wait for gh-54.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/AudioCapturing.swift`, `RecordingProvider.swift`, `DualSourceRecorder.swift` (+ `DualSourceRecorder+Pause.swift` new), `DualSourceRecorder+BuildRecording.swift`, `ChannelHealthController.swift`; test doubles in `Tests/MockRecorder.swift`, `Tests/ChannelFaultIntegrationTests.swift`, `Tests/WatchLoopActiveRecorderTests.swift`, `Tests/DualSourceRecorderLifecycleTests.swift`; new `Tests/DualSourceRecorderPauseTests.swift`, `Tests/ChannelHealthPauseTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/AudioCapturing.swift, app/MeetingTranscriber/Sources/RecordingProvider.swift, app/MeetingTranscriber/Sources/DualSourceRecorder*.swift, app/MeetingTranscriber/Sources/ChannelHealthController*.swift, app/MeetingTranscriber/Tests/MockRecorder.swift, app/MeetingTranscriber/Tests/ChannelFaultIntegrationTests.swift, app/MeetingTranscriber/Tests/WatchLoopActiveRecorderTests.swift, app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift, app/MeetingTranscriber/Tests/DualSourceRecorderPauseTests.swift, app/MeetingTranscriber/Tests/ChannelHealthPauseTests.swift]

## Approach
- **Protocols, no defaults.** `AudioCapturing` (`AudioCapturing.swift:18-36`) gains `func pause()`, `func resume()`; `RecordingProvider` (`RecordingProvider.swift:6-41`) gains `func pause()`, `func resume()`, `var isPaused: Bool { get }`. Deliberately no protocol-extension defaults for these (unlike the reporting properties at `:51-79`): a silent default would let a recorder keep recording while the app says paused. `AudioCaptureSession` conforms through task 1's public methods. Update the doubles: `MockRecorder` (`Tests/MockRecorder.swift:24`: call counts, a settable `isPaused` the methods flip, and a settable `pauseOffsets` its `stop()` returns), `ThrowingRecorder` (`:91`), `BareRecorder` (`Tests/ChannelFaultIntegrationTests.swift:29`), `CapturingRecorder` (`Tests/WatchLoopActiveRecorderTests.swift:5`), `FakeCaptureSession` (`Tests/DualSourceRecorderLifecycleTests.swift:22`).
- **Positions out.** `RecordingResult` (`DualSourceRecorder.swift:12-21`) gains `var pauseOffsets: [TimeInterval] = []` (a `var` with a default keeps every existing memberwise call compiling); `buildRecording` (`DualSourceRecorder+BuildRecording.swift:217-223`) copies `captureResult.pauseOffsets` through; crash recovery passes none.
- **Recorder.** `DualSourceRecorder.pause()` / `resume()` are no-ops unless recording and idempotent, forward to `captureSession`, and set `isPaused`; `stop()` clears it. `DualSourceRecorder.swift` is at 577 lines and `./scripts/lint.sh` runs SwiftLint `--strict` with `file_length` 600: put the pause code in `DualSourceRecorder+Pause.swift` and widen only what it needs (for example `captureSession` from `private` to `private(set)`).
- **Look alive while paused.** Remember the two track URLs `start()` picks (`DualSourceRecorder.swift:424-429`, the raw app temp and the microphone WAV). While paused, a main-actor task sets each existing one's modification date to now every `pausedTrackTouchInterval` (new init parameter, default 10 s, beside the existing test seams at `:111-117`); resume and `stop()` cancel it. Same attribute call as `WavHeaderRepair.swift:77`. The checks it keeps quiet: `recoverCrashedRecordings` (`:345-375`, freshness from `lastTrackWrite` `:260-267`), `cleanupTempFiles` (`:130-148`), `WavHeaderRepair.repairUnfinalized` (`WavHeaderRepair.swift:102-112`).
- **Health hold.** In `ChannelHealthController.applyTick` (`ChannelHealthController.swift:275-350`): when `recorder.isPaused`, skip `notifyChannelFaults` and both monitors, clear `micSilentActive` / `appSilentActive` / `recordingSilentActive`, reset `channelHealthMonitor` and `silentRecordingMonitor`, and remember the pause; on the first unpaused tick after one, restart the fault monitors' since-start clock (`firstTickAt`) and clear `lastSpeechAt`, but do not reset `micFaultMonitor` / `appFaultMonitor`, whose latches keep an already reported fault from being reported again. A give-up flag that flipped during the pause is then reported on that first tick, because the give-up check comes before the window (`ChannelFaultMonitor.swift:120-124`). Keep the new lines small; `ChannelHealthController.swift` is 418 lines and `+Alerts` / `+LogLines` extensions exist for helpers.

## Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/DualSourceRecorder.swift:11-21, 104-117, 392-511` — result type, seams, start, stop
- `app/MeetingTranscriber/Sources/ChannelHealthController.swift:160-418` — start, stop, reset, `applyTick`, fault notifications
- `app/MeetingTranscriber/Sources/ChannelFaultMonitor.swift:63-162` — window, latches, give-up precedence
- `app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift:16-80` — recorder with a fake capture session in a temp staging dir

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/ChannelFaultIntegrationTests.swift:1-60` — `ChannelHealthHarness`, `applyTick` with a `MockRecorder` and a fixed clock
- `app/MeetingTranscriber/Tests/SilentRecordingMonitorTests.swift`, `ChannelHealthMonitor` tests — monitor semantics

## Key context
- Nothing in `WatchLoop` changes here; task 4 calls the recorder. Until then nothing in the app pauses, so behaviour is unchanged.
- `Tests/TestHelpers.swift` is exactly 600 lines: put new helpers in the new test files.
- Commit messages are written for the original project's readers: no fork issue numbers or spec ids.

## Acceptance
- [ ] `DualSourceRecorderPauseTests` (fake capture session, temp staging dir): `pause()` / `resume()` reach the session once each, are idempotent and set `isPaused`; nothing reaches the session when not recording; `stop()` clears `isPaused`; the session's `pauseOffsets` arrive on the `RecordingResult`.
- [ ] With a short injected touch interval, the track files' modification dates advance while paused and stop advancing after resume and after stop; a paused recording older than 30 s is skipped by `recoverCrashedRecordings` and its raw temp survives `cleanupTempFiles` run against the same staging dir.
- [ ] `ChannelHealthPauseTests` through `applyTick` with a `MockRecorder`: inputs that raise the tint, "Recording Appears Silent" and "Capture Channel Silent" when not paused raise none of them while `isPaused` (flags false, no notification); after the resume nothing fires until the window has passed from the resume; a fault reported before the pause is not reported again; a give-up flag set during the pause is reported on the first tick after it.
- [ ] Existing suites unchanged and green: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'DualSourceRecorder|ChannelHealth|ChannelFault|SilentRecording|WatchLoop|WatchingController|BuildRecording' > <scratch>/t3.log 2>&1` (read the log).
- [ ] `./scripts/lint.sh` clean with the pinned tools (fetch them into a temp dir first on `PATH` if not installed); `DualSourceRecorder.swift` stays at or under 600 lines; `./scripts/pre-push.sh` (release build) passes.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
