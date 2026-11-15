---
satisfies: [R6, R11]
---
# gh-171-transcribe-again-and-identify-speakers.3 End a re-run that fails, is cancelled or stays unnamed, and bring it back after a quit

## Description
Every end of a re-run but success, and every restore of one (R6, A2, A5, A23, A24, A25): the per-build re-run file, one end path that writes the record first and removes only the re-run's own files, wired into failure (also the failures a new meeting only warns about), Cancel, Dismiss, the stale-naming cleanup and the launch, plus the row's warning line. The swap's own launch rows are task 4's.

**Size:** M (upper end: the re-run file and the launch table carry most of it)
**Files:** `app/MeetingTranscriber/Sources/PipelineQueue+Rerun.swift`, a new `app/MeetingTranscriber/Sources/PipelineQueue+RerunRecovery.swift`, `app/MeetingTranscriber/Sources/PipelineQueue.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift` (three stage results), `app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift`, `app/MeetingTranscriber/Sources/PipelineSnapshot.swift`, `app/MeetingTranscriber/Sources/PipelineSnapshotStore.swift`, `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift`, `app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift`, `app/MeetingTranscriber/Sources/PipelineController+Notion.swift` (the launch build), `app/MeetingTranscriber/Sources/MeetingFileRemover.swift` (share the file check), `app/MeetingTranscriber/Sources/MeetingFileRecord+Rerun.swift`, `app/MeetingTranscriber/Sources/TranscriptionsView+RowLabels.swift` (status line), new `app/MeetingTranscriber/Tests/PipelineQueueRerunEndTests.swift` and `app/MeetingTranscriber/Tests/PipelineQueueRerunRecoveryTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/PipelineQueue*.swift, app/MeetingTranscriber/Sources/PipelineSnapshot*.swift, app/MeetingTranscriber/Sources/SpeakerNamingSession*.swift, app/MeetingTranscriber/Sources/PipelineController*.swift, app/MeetingTranscriber/Sources/MeetingFileStore.swift, app/MeetingTranscriber/Sources/MeetingFileRemover.swift, app/MeetingTranscriber/Sources/MeetingFileRecord*.swift, app/MeetingTranscriber/Sources/TranscriptionsView*.swift, app/MeetingTranscriber/Tests/PipelineQueueRerun*.swift]

### Approach
- One entry: `applyJobState` (`PipelineQueue.swift:1002-1058`) gets one early branch that hands a re-run job to `PipelineQueue+Rerun.swift`, so its raw-file cleanup, notes-failure clearing, ledger, outcome, finished-job steps and the held-job naming cleanup (its `isHeldAfterCompletion` branch) never run for it (the plan review's structure note), and `onJobStateChange` posts none of the done notifications for it (`PipelineQueue.doneNotification`, `PipelineQueue.swift:578`; its texts say a transcript or notes were saved).
- End path, in this order: mark the record's marker as ending; delete the re-run's own files that pass the file check; one record update restores the outcome from the marker and, when no file is left, clears the marker and notes the stamp as ended (a file that failed the check or its removal stays in the marker, A27); then take the job out of the queue and its file without `noteLeftQueue` (which turns in progress into left unfinished), the ledger mark or `relocateRecordingOfCancelledJob`; a settled entry the re-run took over (task 2) goes back as it was, with its Notion export state and its notes failure (`notesFailure`, `notesSpeakerNames`), so a held entry still offers Retry Notion Export or Retry Meeting Notes and keeps being held (`isHeldAfterCompletion`); the re-run's own notes failure, if it recorded one, does not stay on it. A failed record update is logged and keeps the job in its file.
- File check: a file is removed or renamed only when `lstat` finds a regular file with the identity the marker names, in the resolved folder it names; share `MeetingFileRemover.isTheRecordedFile` (`MeetingFileRemover.swift:126-137`) rather than copy it. A file that fails it stays, the marker stays, the reason is logged as a private value. Admission (task 2's `rerunJob`) first tries the files of a marker left in phase ending and refuses while any stays, with its own reason for the sheet (A27).
- Failures (A25): a re-run job reaching `.error`, and the three a new meeting only warns about: `diarize`'s catch and its not-available skip (`PipelineQueue+Stages.swift:704-775`), `protocolText` returning nil (1297-1340, which since the upstream merge also calls `recordNotesFailure`, while `generateProtocol` keeps the names in `notesSpeakerNames`) and `saveProtocolLocally` returning false (1270-1295, called from `saveGeneratedNotes`, 1228-1268). For a re-run job each becomes a failure its caller turns into the end path before the usual completion, after a confirmed and after a skipped naming alike.
- Cancel and Dismiss: `cancelJob` (`PipelineQueue.swift:980`) returns early for `.done` today; route a re-run job to the end path; the menu's "Needs you" Dismiss of a pending re-run does the same.
- Unanswered naming: `cleanupStalePending` (`PipelineQueue.swift:1405-1416`, forwarding to `SpeakerNamingSession.swift:504-520`, which accepts the automatic names) ends a re-run job instead (A5); with the wait set to never nothing ends it.
- Re-run file (A24): `saveSnapshot` (`PipelineQueue.swift:1434`) writes re-run jobs to a file beside `pipeline_queue.json`, named with the bundle identifier, owner-only and staged as `PipelineSnapshot` writes, and never into `pipeline_queue.json`; `loadSnapshot` (`PipelineQueue+Recovery.swift:102-199`) merges both, the re-run job winning over a finished entry of the same id, and never sends a re-run job down the restore that relocates audio or names a new meeting, nor through `discardFinishedJobs` (74-80), which drops a finished job that is not held and removes its naming data (a re-run whose stamp is noted as committed is `.done` in the file and is task 4's launch row).
- Launch: `PipelineController.activate` (`PipelineController.swift:171-177`) runs `reconcileInterruptedDeletions` before any queue exists, and the first queue may be built much later. `restorePendingNotionExports` (`PipelineController+Notion.swift:8-13`) builds it at launch only when every job in `pipeline_queue.json` is finished and one is held; it does not read the re-run file, so make it count a live re-run job in this build's re-run file as a job that is not finished, and the re-run waits for the first queue like any saved job. Beside it, read this build's re-run file directly (as `jobsTheQueueHasNotRead` reads the snapshot, `PipelineController+LiveMeetingState.swift:56-61`) and apply the Architecture table's rows for a running marker (left for the restore), a marker marked as ending (finish the cleanup), an ended note or no marker and no note (end as R6 from the job's marker), and an orphan (a marker of this build whose job is not in the file and whose process has ended, `DeletionProcess.isRunning`). Only markers with this build's bundle identifier; an unreadable file changes nothing.
- Warning line (A23): kept in memory per job id, "Transcribe Again failed: <reason>" or "Transcribe Again ended: the speakers were not named in time" (the Identify Speakers Again words come with task 6), shown on the finished row until the app quits or the meeting's next re-run is admitted; built by a pure function.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/PipelineQueue.swift:888-1069,1405-1455`
- `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift:684-775,1160-1340`
- `app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift:102-199`
- `app/MeetingTranscriber/Sources/PipelineController.swift:165-245`, `app/MeetingTranscriber/Sources/PipelineController+Notion.swift:1-13` and `app/MeetingTranscriber/Sources/PipelineController+LiveMeetingState.swift:20-61`
- `app/MeetingTranscriber/Sources/MeetingFileRemover.swift:1-40,126-137`
**Optional:**
- `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift:404-440,504-520`
- `app/MeetingTranscriber/Sources/PipelineSnapshot.swift` (staged owner-only writes)
- `app/MeetingTranscriber/Tests/PipelineQueueRetryTests.swift:44-91` (failing engines)
- `app/MeetingTranscriber/Sources/PipelineQueue+MeetingNotes.swift:1-160` and `app/MeetingTranscriber/Tests/MeetingNotesRetryTests.swift` (held notes retry)

### Key context
- The record is the re-run's journal: write it first, then the files, then the job file (memory: a deletion's recovery mark went before the other writes were on disk; here the order is chosen so every crash point reads as one row of the table).
- Both builds share the data folder and `pipeline_queue.json`; only the per-build file keeps a build without this spec from replaying a re-run as a new meeting.
- Ask `MeetingFilePresence` before treating a file as gone (memory: a record assumed what a write did).
- Failure reasons and file names go to logs only as private values.
## Acceptance
- [ ] Each end leaves the transcript, notes, additional reports and segments file byte for byte, the record's outcome as before with no marker and the stamp noted as ended, the finished-job entry byte for byte, and no file of the re-run, one pipeline test per end: a transcription failure; speaker identification failing and not available; notes that cannot be made and that cannot be saved, each after a confirmed and after a skipped naming; Cancel; Dismiss; a naming left past the wait.
- [ ] A finished entry the re-run took over comes back as it was after each end: after a failed Notion export it still offers Retry Notion Export, and after failed notes it still offers Retry Meeting Notes and stays held.
- [ ] A re-run file replaced at its path, or reached through a folder replaced by a symbolic link, stays where it is, and the marker stays listing it; so does a file whose removal fails. The outcome is restored, the next admission tries the file again first and refuses with A27's reason while it stays, and queues the re-run once it is gone.
- [ ] A stop after the marker was marked as ending and before the last record update: the next launch removes the files left and ends the re-run as R6.
- [ ] With the wait set to never, a re-run waiting for names stays waiting across a launch.
- [ ] While a re-run runs, `pipeline_queue.json` holds no re-run job and this build's re-run file holds it; a cold start (`activate`, then the first queue built) resumes it with its marker and never gives it the automatic names of a new meeting.
- [ ] At launch: a marker whose job is in the file is left to the restore; a marker of this build without its job, its process ended, ends as R6; a marker of the other build stays; with the re-run file unreadable every marker stays; a record without marker or note while the job is in the file ends the re-run as R6.
- [ ] The row shows the one warning line after a failure or an unanswered naming, until the next re-run is admitted (pure text test and one ViewInspector check).
- [ ] On every end the meeting's audio paths and bytes are unchanged.
- [ ] The Quick commands' focused tests and `./scripts/lint.sh` pass.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
