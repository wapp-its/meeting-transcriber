---
satisfies: [R1, R5]
---
# gh-46-pause-and-resume-a-recording.4 Pause state in the watch loop

## Description
`WatchLoop` owns the pause: observable state, pause and resume actions with an outcome, the pause log, the diagnostic lines, and the hand-over of the finished pauses to the pipeline job at every end of a recording (spec: Architecture "The pause state lives in WatchLoop", "The pause record"; Edge Cases "Pause before capture is up", "Recording ends while paused", "4-hour cap"; R1 state, status line and log lines; R5 except the gh-54 cut). Needs task 2 (`RecordingPause`, `RecordingPauseLog`, `PipelineJob.pauses`) and task 3 (recorder `pause`/`resume`, `RecordingResult.pauseOffsets`). Build only after gh-54 is merged into `wapp/main`: it reshapes the same `WatchLoop` code and adds the `diagnostics` seam used here.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchLoopState.swift`, `WatchLoop.swift`, `WatchLoop+Pause.swift` (new), possibly `RecordOnlyDestination.swift` (moved out unchanged); new `Tests/WatchLoopPauseTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/WatchLoop*.swift, app/MeetingTranscriber/Sources/RecordOnlyDestination.swift, app/MeetingTranscriber/Tests/WatchLoopPauseTests.swift, app/MeetingTranscriber/Tests/WatchLoopStateTests.swift, app/MeetingTranscriber/Tests/WatchLoopUpdateFunnelTests.swift]

## Approach
- **State.** `WatchLoopState` (`WatchLoopState.swift:8-24`, `.initial`, `snapshot` at `:56-64`) gains `pausedSince: Date?`; `WatchLoop` publishes it like the other fields in `apply` (`WatchLoop.swift:533-545`) and adds `var isPaused: Bool` and `var canPause: Bool` (phase `.recording` and `activeRecorder` set: capture is running; the menu and API read it). Enforce in the funnel that whenever the next phase is not `.recording`, `pausedSince` is nil; nothing but `pauseRecording()` sets it. The loop keeps a `RecordingPauseLog` and the recording's origin: `nowProvider()` read right after the recorder started (gh-54 already reads `recordingStartedAt` there for detected meetings; read it the same way after `recorder.start` in `startManualRecording`, `WatchLoop.swift:258-262`); both reset at every recording start.
- **`WatchLoop+Pause.swift`.** `enum RecordingPauseOutcome { case changed, unchanged, nothingToPause }`. `pauseRecording()`: `nothingToPause` unless `canPause`; `unchanged` while paused; otherwise `activeRecorder.pause()`, `pauseLog.pause(at: nowProvider())`, `pausedSince = now`, `detail = "Paused: <title>"`. `resumeRecording()`: `unchanged` unless paused (also when nothing records); otherwise `activeRecorder.resume()`, log resume, `pausedSince = nil`, `detail = "Recording: <title>"`. Title: `manualRecordingInfo.title`, else `Self.cleanTitle(currentMeeting.windowTitle)` (the same strings `handleMeeting` and `startManualRecording` put in `detail` today). The funnel `update(_:)` is private (`WatchLoop.swift:524-528`); widen it to internal for this extension, as `WatchLoop+Consent.swift` reaches its own state.
- **Log lines.** Through `WatchLoop.diagnostics` (the `DiagnosticsLogging` seam gh-54 adds; if absent, add it with an `OSLogDiagnostics(category: "WatchLoop")` default as `ChannelHealthController.swift:142-148` does): `recording_paused` on pause, `recording_resumed paused_s=<whole seconds>` on resume, and a warning `recording_pause_offsets_fallback` when the capture's positions do not match the log. No title, app name or participant.
- **End of recording.** After `recorder.stop()` in `handleMeeting` and in `stopManualRecording` (`WatchLoop.swift:281-305`), build the job's pauses with `pauseLog.pauses(endingAt: nowProvider(), recordingStartedAt: origin, capturedOffsets: recording.pauseOffsets)` and pass them through `enqueueRecording` (`:468-516`) into `PipelineJob(…, pauses:)`. Leave the record-only branch and gh-54's cut to task 5 (it clips the list and writes the sidecar).
- **Nothing else changes for a paused recording.** `waitForMeetingEnd` / `WatchLoopEndPolicy`, gh-54's countdown and `monitorManualRecording` keep polling as they do; the cap keeps counting wall-clock time. Tests prove it rather than code changing it.
- **Cross-spec wiring with gh-45 (order set by the coordinator).** Check `grep -rn SilencePromptPolicy app/MeetingTranscriber/Sources`. If gh-45 is already merged, hold its silence count while paused (its policy's `held` input, the count restarting at resume) and add a test that a paused recording never reaches its question. If not, do nothing: gh-45 reads `WatchLoop.isPaused` when it is built.
- **Line cap.** `WatchLoop.swift` is near 600 lines after gh-54; if the new stored properties push it over, move `RecordOnlyDestination` (bottom of `WatchLoop.swift`) into `RecordOnlyDestination.swift` unchanged.

## Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchLoop.swift` — start/stop, `handleMeeting`, `stopManualRecording`, `enqueueRecording`, `update`/`apply` (re-read after gh-54 merged; line numbers above are from before it)
- `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift` (from gh-54) — the countdown loop and `recordingStartedAt`
- `app/MeetingTranscriber/Sources/WatchLoopState.swift:8-64` — snapshot, `activeRecordingSource`
- `app/MeetingTranscriber/Tests/WatchLoopMeetingStartTimeTests.swift` — `handleMeeting` with `MockRecorder` and a real `PipelineQueue`, reading `queue.jobs`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/TestHelpers.swift:229-290` — `makeTestWatchLoop`, `TestClock` (construct `WatchLoop` directly with `nowProvider`/`sleepProvider` for timing tests)
- `app/MeetingTranscriber/Tests/WatchLoopTimingTests.swift`, `WatchLoopMonitorTests.swift` — cap and app-exit paths with an injected clock
- `app/MeetingTranscriber/Tests/RecordingDiagnostics.swift` — diagnostics double
- `app/MeetingTranscriber/Tests/WatchLoopStateTests.swift`, `WatchLoopUpdateFunnelTests.swift` — snapshot equality tests to extend

## Key context
- `WatchLoop` is `@MainActor`; its tests must be too.
- The phase stays `.recording` while paused, so `activeRecordingSource`, the channel-health start in `WatchingController.attachStateChangeHandler` and the live-caption gate keep working unchanged.
- `Tests/TestHelpers.swift` is exactly 600 lines: put new helpers in the new test file.
- Commit messages are written for the original project's readers: no fork issue numbers or spec ids.

## Acceptance
- [ ] `WatchLoopPauseTests` (`MockRecorder`, `TestClock`, real `PipelineQueue`): pausing a manual recording returns `changed`, calls the recorder, sets `pausedSince` and detail "Paused: <title>"; a second pause is `unchanged`; resume returns `changed` and restores "Recording: <title>"; resume while running is `unchanged`; pause with nothing recording, and on a detected meeting before its recorder is active (`canPause` false), returns `nothingToPause` and calls nothing.
- [ ] Every end path while paused (manual stop, Stop Watching on a detected meeting, the monitored app quitting, the cap) enqueues one job whose last pause ends at the stop, and leaves `pausedSince` nil. A detected meeting whose signal goes away while paused still ends through the end grace and gh-54's countdown and enqueues one job carrying the pause (clipping at gh-54's cut is task 5); the countdown runs unchanged while paused and its "Keep recording" answer does not resume.
- [ ] A recording paused and resumed enqueues one job with that pause, its offset taken from the recorder's `pauseOffsets`; with offsets of a different count it uses the wall-clock fallback and writes the warning line; a never-paused recording's job has `pauses == nil`; the next recording starts with an empty log.
- [ ] A recording paused past `maxDuration` still ends at the cap (wall-clock, paused time included).
- [ ] The diagnostics double sees `recording_paused` and `recording_resumed paused_s=<n>`, and no line contains the meeting title.
- [ ] If gh-45's `SilencePromptPolicy` is present: a paused recording never reaches its question and its count restarts at resume (otherwise state "not applicable: gh-45 not merged" in the done summary).
- [ ] `WatchLoopStateTests` / `WatchLoopUpdateFunnelTests` cover the new field; `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'WatchLoop|WatchingController|ManualRecording|RecordOnly|MeetingEnd' > <scratch>/t4.log 2>&1` green (read the log).
- [ ] `./scripts/lint.sh` clean with the pinned tools; `WatchLoop.swift` stays at or under 600 lines; `./scripts/pre-push.sh` passes.

## Done summary
The watch loop can now pause and resume the recording in progress. `pauseRecording()` and `resumeRecording()` (new `Sources/WatchLoop+Pause.swift`) return `changed`, `unchanged` or `nothingToPause`. The loop publishes `pausedSince` (also on `WatchLoopState`), shows "Paused: <title>" in the status line, and writes `recording_paused` / `recording_resumed paused_s=<n>`. At every stop it hands the recording's pauses to the `PipelineJob`, and it holds gh-45's long-silence question while the recording is paused. Nothing in the UI or API calls pause yet (task .6).

stage: impl-review - skipped(policy: parallel-wave - conductor owns the review after integration)

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

baseline: green via handoff (conductor, at 24d36763; only .flow/ changed since 79f6a060, checked with git log --name-only) + lint measured green pre-edit (`./scripts/lint.sh`, 0 violations)

### Gates (worker, on lane commit f682c974, all measured)

- Focused: `WatchLoopPauseTests|WatchLoopStateTests|WatchLoopUpdateFunnelTests`, 21 tests, rc 0.
- Task AC filter `WatchLoop|WatchingController|ManualRecording|RecordOnly|MeetingEnd` (scratch home /tmp/gh46-home-t4), 324 tests, rc 1. The only failures are the 5 known environmental `WatchLoopE2ETests` (WhisperKit model load: "unloaded is not equal to loaded", job "error"). The serial rerun of that class with `CFFIXED_USER_HOME=/tmp/gh46-home-t2b` (complete model) passed 8/8, rc 0.
- Spec app Quick filter (`RecordingPause|WatchLoopPause|...|RecordingSidecar`), 293 tests, rc 0.
- `./scripts/lint.sh` with the pinned tools, rc 0, 0 violations in 798 files.
- `./scripts/pre-push.sh`, rc 0 ("pre-push parity check passed").
- `flowctl gate classify` exit 1 (FULL), so the focused commands above ran and no GATE_SKIPPED line applies.
- Mutation check: six one-point mutations, each applied alone and restored from HEAD. Each failed its intended test. M1: the funnel no longer clears `pausedSince`. M2: the silence question is not held. M3: the resume flag is ignored. M4: captured offsets are ignored. M5: `canPause` ignores the recorder. M6: the pauses end at the start. The failing tests per mutation are in /tmp/gh46-tick/w4/mutations-all.txt.
- Not run: CI's `swiftlint analyze` (`unused_declaration`), which needs a clean `xcodebuild build-for-testing`. A grep finds a reference for every new declaration (inferred clean). App Store variant build (`pre-push.sh --with-appstore`) not run. No `#if APPSTORE` code was touched.
- `WatchLoop.swift` grew from 576 to 590 lines (cap 600). `RecordOnlyDestination` was already in `WatchLoop+RecordOnly.swift`, so nothing moved.

### Tests by acceptance criterion (`Tests/WatchLoopPauseTests.swift` unless named)

1. Outcomes, recorder calls, `pausedSince`, detail, a second pause, and a resume while running are covered by `testPausingAndResumingAManualRecording`. Nothing recording, and a detected meeting before its recorder is up, are covered by `testThereIsNothingToPauseWithoutARunningCapture`.
2. End paths while paused, each with one job whose last pause ends at the stop and `pausedSince` nil:
   - `testAPausedManualRecordingEndsLikeARunningOne` covers Stop Recording, the app quitting and the cap.
   - `testAPausedDetectedMeetingEndsLikeARunningOne` covers Stop Watching and the cap.
   - `testASignalLostWhilePausedStillEndsThroughGraceAndCountdown` covers a signal lost while paused. The grace and countdown give the unchanged auto-stop line `signal_absent_s=130`, a resume during the countdown does not answer it, and the job carries the pause.
   - `testKeepRecordingDoesNotResumeAPausedRecording`: Keep recording does not resume the recording.
3. Job pauses from the recorder's `pauseOffsets`, and the wall-clock fallback with its warning: `testThePausesReachTheJobAtTheCapturesPositionsOrTheWallClocks`. A never-paused job has nil pauses, and the next recording starts with an empty log: `testTheNextRecordingStartsWithAnEmptyPauseLog`.
4. The cap counts paused time: the "maximum length" rows of both end-path tests (paused at 10 s or 5 s, cap 30 s, the recording ends at 31 s).
5. Diagnostics: exact lines `["recording_paused", "recording_resumed paused_s=20"]` in the pause test. No line contains "Quarterly Review" in the detected end-path test.
6. gh-45 is merged, so this criterion applies. `testAPausedRecordingNeverReachesTheSilenceQuestion` has three rows. Never paused asks at 300 s. Paused 100-1000 s asks at 1300 s. Paused and resumed between two polls at 200 s asks at 500 s.
7. `WatchLoopStateTests` (initial nil, `testSnapshotReflectsThePause`) and `WatchLoopUpdateFunnelTests.testAPauseIsKeptOnlyWhileRecording`.
8. Lint, line cap and pre-push are covered by the gates above.

### Decisions

- D-a (rule 6): one optional stored `recordingPauses: RecordingPauseRecord?` (the log plus the origin) on `WatchLoop`. The loop makes a new record at each capture start, from the same `nowProvider()` read that the cut uses as its origin. `takeRecordingPauses` takes the record and sets it to nil at the stop. Alternatives: two separate stored properties, or reuse `silencePrompt.manualStartedAt` and the local `recordingStartedAt`. Switch point: `WatchLoop.recordingPauses`, `WatchLoop+Pause.swift:takeRecordingPauses`. Test: `testTheNextRecordingStartsWithAnEmptyPauseLog`.
- D-b (rule 1, conductor note that `RecordingCut.redirect` drops `pauseOffsets`): both stop paths take the pauses right after `recorder.stop()` and before `cutBack`. The pauses end at the `stoppedAt` read just before the stop, which is the instant the cut uses. They do not end at a `nowProvider()` read after the stop. To allow this, `stopManualCapture` now returns `(recording:, pauses:)`. Alternative: carry `pauseOffsets` through the redirect in `cutBack` (task .5's surface). Switch point: `WatchLoop.handleMeeting`, `WatchLoop+SilencePrompt.swift:stopManualCapture`. Tests: the end-path tests, mutation M6.
- D-c (rule 5): the silence hold lives in one place, `stepSilencePrompt(held:trigger:)`, as `held || isPaused || resumedSinceLastPoll`. It does not live at the two call sites. `resumeRecording()` sets `SilencePromptRuntime.resumedSinceLastPoll`, so the first poll after any resume is held. The count then restarts at the resume, also after a pause that began and ended between two 3 s polls. This applies the memory entry `channel-health-hold-missed-a-sub-poll-2026-10-14`. Alternatives: `held: isPaused` at both call sites, or rely on `ChannelHealthController.speechActivity` restarting its clock at the resume. Switch point: `stepSilencePrompt`, `SilencePromptRuntime.resumedSinceLastPoll`. Test: the three rows of `testAPausedRecordingNeverReachesTheSilenceQuestion`, mutations M2 and M3.
- D-d (rule 6): the fallback warning reads `recording_pause_offsets_fallback pauses=<n> captured=<m>`. It also fires when the capture reported positions and the log has none. Switch point: `takeRecordingPauses`. Test: the "another count" row.
- D-e (rule 6): `paused_s` is rounded to whole seconds with `.rounded()`, the same way as `kept_s` and `silent_s`. Switch point: `resumeRecording`. Test: `testPausingAndResumingAManualRecording`.
- D-f (rule 1, task Approach "leave the record-only branch and gh-54's cut to task 5"): `enqueueRecording` takes `pauses` with no default, so every stop path must pass them, and the parameter comes before the defaulted `participants`. The record-only branch ignores the pauses, and no cut clips them. Test: the signal-lost test does not assert `endedAt`, which task .5 clips.
- D-g (rule 6): `isPaused`, `canPause` and `RecordingPauseOutcome` live in `WatchLoop+Pause.swift`. Pause and resume are not `@discardableResult`. The funnel rule is enforced inside `update(_:)`, which is now internal. Test: `testAPauseIsKeptOnlyWhileRecording`, mutation M1.
- D-h (rule 6): the doc comments "five observable fields" now say "six" (`WatchLoopState.swift`, `WatchLoopStateTests.swift`). The funnel test header no longer says that `update` is private.

### Notes for the conductor

- Integration notes for tasks .5 and .6 are in the run-notes file `task4-watchloop-pause-notes.md`.
- No route to a mapped feature changed. Pause is not reachable from the menu or the API yet.
- Touches: every changed file is inside the declared set (`WatchLoop+SilencePrompt.swift` matches `WatchLoop*.swift`).

### Review and integration (conductor)

stage: impl-review - ran [codex gpt-6-astra xhigh; round 1: three draws (correctness, contracts, integration) all SHIP, 0 findings; no fix pass]

Integrated onto feat/gh-46-pause-recording as 735b87fb (lane commit f682c974), base 24d36763. Focused integrated verify at 735b87fb: task and spec filters 581 tests with 5 environmental WatchLoopE2E failures (fresh scratch home without a model) that pass 8/8 in a serial rerun with a complete model; lint exit 0; pre-push exit 0.

Conductor decisions on the worker's report: D-c (the silence hold inside stepSilencePrompt with resumedSinceLastPoll) is a rule-5 assumption, recorded as A13 in the spec; D-a, D-d, D-e, D-g, D-h (rule 6) and D-b, D-f (rule 1) accepted as reported. gh-45 wiring: applied (gh-45 merged), a paused recording never reaches the long-silence question.

Notes carried to tasks .5 and .6: pauses are taken right after recorder.stop() and before cutBack in both stop paths and are not clipped (task .5 clips them at the cut and writes the sidecar); pause is not reachable from the menu or the API yet (task .6).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 735b87fb278fb7036b293b270306cd6badb17af3
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/gh46-home-c4 swift test --parallel --filter 'WatchLoop|WatchingController|ManualRecording|RecordOnly|MeetingEnd|RecordingPause|DualSourceRecorderPause|ChannelHealth|RecordControl|RPCRecordStatus|MenuBar|EmptyTrack|RecordingSidecar' (integrated head 735b87fb: 581 tests, 5 failed, all WatchLoopE2ETests under a fresh scratch home without a WhisperKit model), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/gh46-home-t2b swift test --filter 'WatchLoopE2ETests' (flaky-gate rerun, serial, scratch home with a complete model: exit 0, 8 tests, 0 failures), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (integrated head 735b87fb: exit 0, 0 violations in 798 files), ./scripts/pre-push.sh (integrated head 735b87fb: exit 0, release build parity), worker at lane head f682c974 (same tree): focused 21 tests exit 0; task AC filter 324 tests with the 5 environmental E2E failures, serial rerun 8/8; spec app Quick filter 293 tests exit 0; lint exit 0; pre-push exit 0; 6 single-point mutations each failed their intended test, review: codex gpt-6-astra xhigh, round 1 three draws (correctness, contracts, integration) all SHIP, 0 findings (receipt /tmp/impl-review-receipt-d1afe3212e3b-gh-46-pause-and-resume-a-recording.4.json), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'WatchLoop|WatchingController|ManualRecording|RecordOnly|MeetingEnd', ./scripts/lint.sh, ./scripts/pre-push.sh
- PRs: