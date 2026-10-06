---
satisfies: [R1, R3, R4]
---
# gh-60-cut-a-recovered-recording-back-after-a.3 Store the cut when the meeting-end question opens and settle it on every end

## Description
The watch loop decides when: store before the question is posted; clear when the question is taken back; clear a settled question's cut before the recorder stops; for a cut-carrying stop, record the resolved cut before any track changes and clear after the cut; never clear on a cut-carrying stop that failed. Logs the write and removal failures, and carries the docs for the whole spec. See spec Architecture (who writes and removes it, the resolved cut), Edge Cases, R1, R3, R4.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift`, `app/MeetingTranscriber/Sources/WatchLoop.swift`, `app/MeetingTranscriber/Tests/WatchLoopMeetingEndTests.swift`, `docs/architecture-macos.md`
**Touches:** [app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Tests/WatchLoopMeetingEndTests.swift, docs/architecture-macos.md]

### Approach
- Store in the `.askToEnd` arm (`WatchLoop+MeetingEnd.swift:55-57`) BEFORE `askToEnd(meeting)` posts the notification, through the active recorder (`activeRecorder`, `WatchLoop.swift:30`, set at `:409`) with `pending.cutAt`, `pending.deadline` and the recording's start on the loop clock (`recordingStartedAt`, `WatchLoop.swift:412`; pass it into `waitForMeetingEnd` or keep it on the loop, implementer's call; the direct `waitForMeetingEnd(meeting)` calls in tests run without a recorder and store nothing). Failure → `diagnostics.warning("pending_cut_write_failed domain=<d> code=<c> published=<true|false>")` (task 2's error says which), countdown carries on.
- Clear in the `.withdrawQuestion` arm (`:59-61`, Keep or a returning signal), unconditionally, also when the store had failed: a failed store may have published its record. NOT in the `defer` at `:41`: that also runs on the cut-carrying exits.
- In `handleMeeting` (`WatchLoop.swift:430-446`): when `waitForMeetingEnd` returns no cut (a Keep just before Stop Watching via `cutWhenWatchingStops`, `WatchLoopEndPolicy.swift:170-176`; the cap together with a Keep or a returning signal via `capStop`, `:182-201`; or no question at all), clear BEFORE `recorder.stop()`. With a cut: `recorder.stop()`, then `cutBack`, then clear, before `enqueueRecording`. A throwing `recorder.stop()` leaves the function before the clear (task 2 releases the hold).
- In `cutBack` (`WatchLoop+MeetingEnd.swift:81-106`): after `keptSeconds` is computed and before `RecordingCut.apply`, call `recordPendingCutResolution(keptSeconds:captureEndedAt: stoppedAt)` on the active recorder; a failure logs `pending_cut_write_failed` and the cut proceeds (spec A7).
- Removal failure: `diagnostics.warning("pending_cut_remove_failed domain=<d> code=<c> emptied=<true|false>")`, no path.
- Keep `WatchLoop.swift` additions to calls of helpers that live in `WatchLoop+MeetingEnd.swift`: the file is at 580 lines against SwiftLint's 600-line warning.
- `docs/architecture-macos.md`: rows for `PendingRecordingCut.swift` and `RecoveredCut.swift` in the file tables (near `WatchLoopEndPolicy.swift` at `:135` and the recovery rows at `:167`/`:185`), and one sentence in the crash-recovery text (`:424`) that a stored meeting-end cut is applied before a recovered recording is queued. Do not edit `CLAUDE.md`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift` — the question lifecycle, the defer, cutBack
- `app/MeetingTranscriber/Sources/WatchLoop.swift:392-447` — handleMeeting's start, wait, stop, cut, enqueue
- `app/MeetingTranscriber/Sources/WatchLoopEndPolicy.swift` — which exits carry a cut (`ask`, `capStop`, `cutWhenWatchingStops`)
- `app/MeetingTranscriber/Tests/WatchLoopMeetingEndTests.swift` — the harness (`makeLoop`, injected clock, `RecordingNotifier`, `RecordingDiagnostics`) and the countdown scenarios to extend (`:145`, `:190`, `:300`, `:335`, `:362`)

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/MockRecorder.swift` — the ordered call log and failure switches from task 2

### Key context
- Assert order on one log: the store comes before the notification post (compare against `RecordingNotifier`'s record), the clear before `stop` for a stop without a cut, and the resolution while the WAV fixture tracks are still uncut (task 2's closure hook).
## Acceptance
- [ ] Question opens: the stored cut carries the policy's `cutAt` and `deadline` and the recording's start, and is stored before the notification is posted.
- [ ] A store failure logs `pending_cut_write_failed … published=…` and the countdown still ends the recording cut back as before.
- [ ] After a store that failed with its record published, "Keep recording" and a returning signal still call the clear (MockRecorder log), so the record never outlives the settled question.
- [ ] A returning signal clears it at the withdraw; a later loss stores a fresh one with the new cut point.
- [ ] "Keep recording" clears it at once; the recording later ends uncut (cap or Stop Watching) with no stored cut left.
- [ ] Keep answered just before Stop Watching, and the cap reached on the poll that sees a Keep: the stored cut is cleared before `recorder.stop()`; with a throwing `stop()` the clear has still happened.
- [ ] Countdown expiry, "Stop now", Stop Watching during the question and the cap during the question: nothing is cleared before `recorder.stop()`; the resolution (`keptSeconds` equal to the seconds the tracks are cut to, `captureEndedAt` = the stop time) is recorded while the tracks are still uncut; after the cut the stored cut is cleared exactly once.
- [ ] A failed cut still clears the stored cut (recording processed uncut, as in gh-54); a failed resolution write logs and the cut still happens.
- [ ] A throwing `recorder.stop()` on a cut-carrying stop clears nothing.
- [ ] A removal failure logs `pending_cut_remove_failed … emptied=…` with no path.
- [ ] Manual recordings never store a cut.
- [ ] `docs/architecture-macos.md` names the new files and the recovery step; `CLAUDE.md` untouched; `WatchLoop.swift` stays under 600 lines; focused tests and lint pass.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
