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
The recorder can pause: `RecordingProvider` and `AudioCapturing` gain required `pause()`/`resume()` (plus `RecordingProvider.isPaused`), `DualSourceRecorder` forwards them to the capture session, carries the session's pause positions out on `RecordingResult.pauseOffsets` and refreshes its track files' modification dates every 10 s while paused so the staging recovery never takes a paused recording for a crashed one; `ChannelHealthController.applyTick` holds every check while the recorder reports paused and restarts its windows at the resume. Nothing in the app calls pause yet (task .4).

stage: impl-review - skipped(policy: parallel-wave - conductor owns the review)

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

baseline: red (pre-edit, acceptance filter: 488 tests, 5 WatchLoopE2ETests failures from WhisperKit model loading under the parallel scratch home; environmental, the same 5 fail identically after the change and all 8 pass serially in a fresh home); lint 0 violations

### Acceptance

- `DualSourceRecorderPauseTests` (fake capture session, temp staging dir, 20 ms touch interval): `testPauseAndResumeReachTheSessionOnceEach` (once each, idempotent, `isPaused`), `testNothingReachesTheSessionOutsideARecording` (before start, after stop; stop clears `isPaused`), `testTheSessionsPausePositionsArriveOnTheRecording`, `testAPausedRecordingKeepsItsTracksFresh` (dates advance while paused; not after resume, not after stop), `testAPausedRecordingIsNeitherRecoveredNorCleanedUp` (tracks backdated 60 s, paused; `recoverCrashedRecordings` recovers only a crashed sibling, `cleanupTempFiles` deletes only an orphan sibling, the paused raw temp survives).
- `ChannelHealthPauseTests` through `applyTick` with `MockRecorder`: `testNothingIsRaisedWhilePausedNorUntilTheWindowHasPassedFromTheResume` (tint, "Recording Appears Silent", "Capture Channel Silent": 20 s lead-in, 300 s pause with nothing raised, nothing in the 30 s after resume, raised exactly at resume + 30 s), `testAPauseClearsTheFlagsAlreadyRaised`, `testAFaultReportedBeforeThePauseIsNotReportedAgain`, `testAGiveUpDuringThePauseIsReportedOnTheFirstTickAfterIt` ("Capture Channel Lost" not posted while paused, posted on the first tick after).
- Mutation check (measured): seven one-line mutations of the new code each fail their intended test (see evidence).
- Existing suites: acceptance filter 497 tests, only the 5 pre-existing environmental WatchLoopE2ETests failures (identical file:line set to baseline); those 8 E2E tests pass serially in a fresh scratch home (exit 0). Spec app Quick filter exit 0 (280 tests).
- `./scripts/lint.sh` exit 0 (0 violations). `./scripts/pre-push.sh` exit 0 (95 s).
- `DualSourceRecorder.swift`: 681 lines before, 652 after (does not grow; the `file_length` disable stays). The room came from moving `downmixToMono` and `crossCheckAppRate` unchanged into `DualSourceRecorder+BuildRecording.swift` (own commit). `ChannelHealthController.swift`: 429 -> 461.
- Not run: CI's `swiftlint analyze` (unused_declaration, needs an xcodebuild log). Every new declaration has a reference (`MockRecorder.pauseCallCount`/`resumeCallCount` are written by `pause()`/`resume()`; task .4's tests read them). App Store variant build (`pre-push.sh --with-appstore`) not run; no `#if APPSTORE` code was touched.

### Decisions

1. (1) `DualSourceRecorder.swift` must not grow (conductor fact, spec Line caps). Alternative: let it grow by 12 lines under the existing disable. Switch: the location of `downmixToMono`/`crossCheckAppRate` (now `DualSourceRecorder+BuildRecording.swift`). Test: `DualSourceRecorderTests` (downmix, cross-check) unchanged and green in the acceptance filter.
2. (6) The recorder's pause state is one stored `pauseState: RecorderPauseState` (track URLs + toucher task) in the main file; `isPaused` is derived as "the toucher is running". Alternative: separate `isPaused` flag beside the task. Switch: `DualSourceRecorder+Pause.swift` `isPaused`. Test: `testPauseAndResumeReachTheSessionOnceEach`, `testNothingReachesTheSessionOutsideARecording`.
3. (6) The first touch comes one interval after the pause, not at the pause instant (the last write is the pause instant itself). Switch: `touchTracksWhilePaused`. Test: `testAPausedRecordingKeepsItsTracksFresh`.
4. (6) The toucher also ends when the recorder is deallocated (`[weak self]`), so a recorder dropped without a stop cannot keep a dead recording looking alive; a failed touch logs one warning per pause (no path). Switch: `touchTracksWhilePaused`. Test: none for the deallocation or the warning (not observable without a failing file system).
5. (6) `buildRecording` copies `pauseOffsets` as reported, also in a degraded single-track fallback (one track unreadable or empty), where the saved timeline's origin can differ from the offsets' origin by the mic delay (typically well under a second). Alternative: shift the offsets there. Switch: `DualSourceRecorder+BuildRecording.swift` return. Test: `testTheSessionsPausePositionsArriveOnTheRecording`.
6. (1) `MockRecorder.stop()` clears `isPaused`, mirroring the `RecordingProvider` contract that `stop()` ends an open pause. Alternative: leave it to the test. Switch: `MockRecorder.stop()`. Test: none in this task (task .4's end-path tests rely on it).
7. (6) Channel health: the monitors are reset and the flags cleared once, at the pause edge, rather than on every paused tick (same behaviour, no 10 Hz observable writes). Levels and ages readouts (`micAges`, `micLevelDBFS`, ...) keep updating while paused; `lastSpeechAt` does not (it is cleared at the resume anyway). Switch: `ChannelHealthController.holdWhilePaused`. Test: `ChannelHealthPauseTests`.
8. (6) `applyTick` returns nil while paused. Switch: `applyTick`. Test: covered implicitly.

### Notes for the conductor

- `RecordingCut.redirect(_:to:)` (outside this task's Touches) rebuilds `RecordingResult` field by field and drops `pauseOffsets`; task .5 or .4 must read the offsets before a redirect or carry them through it. Details in the run notes file `task3-recorder-pause-notes.md`.
- During a pause `ChannelHealthController.speechActivity` keeps the pre-pause clock and last speech; gh-45's question must be held by the watch loop (task .4).
- Phase 1b reference read after implementation; `IMPLEMENTER` "opus at xhigh" is the session model, so the phase was inert either way and no `implement` stage line applies.
- Follow-ups (not filed, outside this task's surface): none beyond the two notes above.

### Review and integration (conductor)

stage: impl-review - ran [codex gpt-6-astra xhigh; round 1: three draws, correctness SHIP, contracts and integration NEEDS_WORK with two R7 findings, merged to 2, validator kept 2; fix pass by an Opus xhigh worker; round 2: single re-review SHIP, both prior findings fixed]

Integrated onto feat/gh-46-pause-recording as b9252111, b680700e, 38d24390 (implementation) and b53fca92, 79f6a060 (review fixes), base 428b358f. Focused integrated verify at 79f6a060: app filter 685 tests with 5 environmental WatchLoopE2E failures (fresh scratch home without a model) that pass 8/8 in a serial rerun with a complete model; lint exit 0; pre-push exit 0.

Review findings fixed:
1. P2 (R7): a pause and resume between two 100 ms polls never set heldForPause. Fix: RecordingProvider.pausesBegun (required, no default) counted by DualSourceRecorder; ChannelHealthController.holdWhilePaused treats a changed count as both edges (spec A12).
2. P2 (R7): a watchdog rebuilds-exhausted give-up during a pause was reported on the first resumed tick. Fix: after a resume the flag reaches the fault monitor only after a whole window of post-resume silence; latches and the terminal give-up report unchanged.

Conductor decisions on the worker's report: the acceptance item 'DualSourceRecorder.swift stays at or under 600 lines' read as no growth (681 before, 652 after, file_length disable kept; the spec's Line-caps bullet records why) (rule 6); decisions 1-8 of the worker and the fix pass's counter-on-the-recorder choice (rule 5, recorded as A12) accepted.

Notes carried to tasks .4/.5: RecordingCut.redirect(_:to:) drops pauseOffsets (read them before a redirect, task .5); ChannelHealthController.speechActivity keeps its pre-pause clock, so gh-45's silence question is held by the watch loop (task .4).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: b92521117aae61035eeb329097159b8ca4dcb00e, b680700eb73e4fa5f09ca08a7842a721dfc00619, 38d243902ffb132251d024415530c405c8c83235, b53fca92aaeef27e0db8a657a63c43e99ddbabec, 79f6a0608bd1db93b3152e232d08f4c77a90d360
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/gh46-home-c3 swift test --parallel --filter 'DualSourceRecorder|ChannelHealth|ChannelFault|SilentRecording|WatchLoop|WatchingController|BuildRecording|RecordingPause|RecordControl|RPCRecordStatus|MenuBar|EmptyTrack|RecordingSidecar' (integrated head 79f6a060: 685 tests, 5 failed, all WatchLoopE2ETests under a fresh scratch home without a WhisperKit model), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/gh46-home-t2b swift test --filter 'WatchLoopE2ETests' (flaky-gate rerun, serial, scratch home with a complete model: exit 0, 8 tests, 0 failures), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (integrated head 79f6a060: exit 0, 0 violations in 796 files), ./scripts/pre-push.sh (integrated head 79f6a060: exit 0, release build parity), worker at lane head 1202eeb1 (same tree as 38d24390): acceptance filter 497 tests with the same 5 environmental E2E failures as its pre-edit baseline; WatchLoopE2ETests serial fresh home 8/8; spec app Quick filter 280 tests exit 0; lint exit 0; pre-push exit 0; 7 single-line mutations each failed their intended test, fix pass at lane head fdbdf550 (same tree as 79f6a060): focused filter 446 tests exit 0; lint exit 0; pre-push exit 0; new tests red before the fix for the stated reason, review: codex gpt-6-astra xhigh, round 1 three draws (correctness SHIP, contracts NEEDS_WORK, integration NEEDS_WORK) merged to 2 findings, validator kept 2; round 2 single re-review SHIP (receipt /tmp/impl-review-receipt-d1afe3212e3b-gh-46-pause-and-resume-a-recording.3.json), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'DualSourceRecorder|ChannelHealth|ChannelFault|SilentRecording|WatchLoop|WatchingController|BuildRecording', ./scripts/lint.sh, ./scripts/pre-push.sh
- PRs: