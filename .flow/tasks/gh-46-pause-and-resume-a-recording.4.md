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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
