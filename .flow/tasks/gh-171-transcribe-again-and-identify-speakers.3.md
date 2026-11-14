---
satisfies: [R6, R11]
---
# gh-171-transcribe-again-and-identify-speakers.3 End a re-run that fails, is cancelled or stays unnamed with the meeting as it was

## Description
Every end of a re-run but success (R6, A2, A5, A23): one end path that removes only the re-run's own files and restores the record from the marker, wired into failure, Cancel, Dismiss, the stale-naming cleanup, the restore after a quit and the launch reconcile, plus the row's warning line.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/PipelineQueue+Rerun.swift`, `app/MeetingTranscriber/Sources/PipelineQueue.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift`, `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift`, `app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift`, `app/MeetingTranscriber/Sources/TranscriptionsView.swift` (status line), a new `app/MeetingTranscriber/Tests/PipelineQueueRerunEndTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/PipelineQueue*.swift, app/MeetingTranscriber/Sources/SpeakerNamingSession*.swift, app/MeetingTranscriber/Sources/PipelineController*.swift, app/MeetingTranscriber/Sources/MeetingFileStore.swift, app/MeetingTranscriber/Sources/MeetingFileRecord*.swift, app/MeetingTranscriber/Sources/TranscriptionsView*.swift, app/MeetingTranscriber/Tests/PipelineQueueRerun*.swift]

### Approach
- One end path: delete only the files the marker names as the re-run's own, by exact name; restore the record's outcome from the marker and clear it; leave the finished-job entry; take the live job out of the queue without `noteLeftQueue` (which turns in progress into left unfinished), the ledger mark or `relocateRecordingOfCancelledJob`.
- Failure: a re-run job reaching `.error` in `applyJobState` (`PipelineQueue.swift:978-1030`) takes the end path instead of `recordTerminalJob` (1046) and `noteOutcome`'s `.failed`.
- Cancel and Dismiss: `cancelJob` (956) returns early for `.done` today; route a re-run job to the end path; the menu's "Needs you" Dismiss of a pending re-run does the same.
- Unanswered naming: `cleanupStalePending` (`PipelineQueue.swift:1370-1381`, forwarding to `SpeakerNamingSession.swift:504-520`, which accepts the auto-names) ends a re-run job instead (A5); with the wait set to never nothing ends it.
- Quit or crash: `loadSnapshot` (`PipelineQueue+Recovery.swift:102-199`) restores a re-run job with its marker and resumes it; it must never take the restore path that relocates audio or treats it as a new meeting. A record marker whose job this build's queue does not hold at launch, in a record this build created (`createdBy`), is restored and cleared beside `reconcileInterruptedDeletions` (`PipelineController+Transcriptions.swift:104`); another build's marker is left alone.
- Warning line (A23): kept in memory per job id, "Transcribe Again failed: <reason>" or "Transcribe Again ended: the speakers were not named in time" (the Identify Speakers Again words come with task 6), shown on the finished row until the app quits or the meeting's next re-run is admitted; built by a pure function.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/PipelineQueue.swift:864-1052,1370-1381,1490-1524`
- `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift:404-440,504-520`
- `app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift:102-199,320-360`
- `app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift:100-131`
**Optional:**
- `app/MeetingTranscriber/Tests/PipelineQueueRetryTests.swift:44-91` (failing engines)
- `app/MeetingTranscriber/Tests/LateRerunCancelTests.swift`

### Key context
- Clear the marker only after the snapshot and record writes before it have landed (memory: a deletion's recovery mark went before the other writes were on disk); `TerminalJobStore` and the snapshot worker log and continue.
- Ask `MeetingFilePresence` before treating a file as gone (memory: a record assumed what a write did).
- Failure reasons and file names go to logs only as private values.

## Acceptance
- [ ] A failure in transcription, in diarization and in the notes, Cancel, Dismiss, and a naming left past the wait each leave the transcript, notes, additional reports and segments file byte for byte, the record's outcome as before with no marker, the finished-job entry byte for byte, and no file of the re-run (one pipeline test per end).
- [ ] With the wait set to never, a re-run waiting for names stays waiting across a launch.
- [ ] After a quit while the re-run runs, the restore resumes it with its marker and the current files stay; a restored re-run is never given the automatic names of a new meeting.
- [ ] At launch, a marker without its job in a record this build created is cleared and its outcome restored; a marker written by the other build stays.
- [ ] The row shows the one warning line after a failure or an unanswered naming, until the next re-run is admitted (pure text test and one ViewInspector check).
- [ ] On every end the meeting's audio paths and bytes are unchanged.
- [ ] The Quick commands' focused tests and `./scripts/lint.sh` pass.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
