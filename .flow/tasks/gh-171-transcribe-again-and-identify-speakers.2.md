---
satisfies: [R4, R11]
---
# gh-171-transcribe-again-and-identify-speakers.2 Re-run a finished meeting through the pipeline under file names of its own

## Description
The early proof point: `PipelineQueue` admits a finished meeting again, rebuilt from its finished-job entry and record, runs it through transcription, speaker identification and naming under a run stem of its own, and hands its files to a success hook that task 4 fills. Non-success ends are task 3. Split this way so the core mechanism is proven before the swap and the endings build on it.

**Size:** M
**Files:** a new `app/MeetingTranscriber/Sources/PipelineQueue+Rerun.swift`, `app/MeetingTranscriber/Sources/PipelineJob.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift`, `app/MeetingTranscriber/Sources/PipelineQueue.swift`, a new `app/MeetingTranscriber/Sources/MeetingFileRecord+Rerun.swift`, `app/MeetingTranscriber/Sources/MeetingFileStore.swift`, a new `app/MeetingTranscriber/Tests/PipelineQueueRerunTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/PipelineQueue*.swift, app/MeetingTranscriber/Sources/PipelineJob.swift, app/MeetingTranscriber/Sources/MeetingFileRecord*.swift, app/MeetingTranscriber/Sources/MeetingFileStore.swift, app/MeetingTranscriber/Sources/SpeakerNamingSession*.swift, app/MeetingTranscriber/Tests/PipelineQueueRerun*.swift]

### Approach
- Entry point `PipelineQueue.rerunJob(id:mode:)` returning queued or a refusal reason; mode is Transcribe Again now, Identify Speakers Again joins in task 6. Follow Retry (`PipelineQueue+Retry.swift:42-58`) for the checks and the trigger, but do not remove the finished-job entry (Architecture: it stays as it was).
- Rebuild the job from `TerminalJobRecord` (title, app, start time, time first added, participants) and the record (source tracks by roles `mix`, `appTrack`, `micTrack`, or the import's own file; run inputs through task 1's resolver). `id`, `enqueuedAt`, `micDelay` and `protocolBackground` are `let` and the Notion ids `private(set)` (`PipelineJob.swift:80-130, 372-417`): add a rebuild initializer rather than mutating. Set the template before enqueueing, since `stampTranscriptOutputOptions` fills a nil one from today's rules.
- Re-run marker (Architecture): an optional Codable field on `PipelineJob` (so the snapshot keeps it) and on the record; admission writes the record's marker under the record file's lock and refuses a record that is not finished, has a pending or incomplete deletion, or already has a marker. Also refuse a job id that is live in the queue, audio held by another run (`audioIsHeldElsewhere`, Retry 110-128), and source audio gone or unreachable, saying which (`MeetingFilePresence.of`).
- Run stem: `makeContext` (`PipelineQueue+Stages.swift:107-121`) derives the slug from title, id and start time, the same as the first run, and that slug names the draft, transcript, 16 kHz copies, segments, naming files and notes. A re-run uses a stem of its own derived from the marker's stamp, chosen so that gh-190's report rule and the folder scans (`AdditionalReport.swift`, `MeetingReportScan.swift`) never claim its files.
- Skip for a re-run: the audio move and its registry entry (`persistAudioToOutput`, Stages ~1003-1005), the processed-recordings ledger (`applyJobState` ~1015, `removeJob` ~873) and the AI-title rename (`renameJobArtifacts`, called ~1164-1170; A8).
- Queue it at the end like an import (A14). `noteOutcome` already sets the record's outcome to in progress on `.waiting`; the marker keeps the outcome before it.
- Success hook: once speakers are confirmed or skipped and the notes are saved or not wanted, call one hook with the re-run's file set; task 4 implements it, here a test double records it.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/PipelineQueue+Retry.swift:42-128`
- `app/MeetingTranscriber/Sources/PipelineJob.swift:76-130,372-417`
- `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift:107-161,976-1074`
- `app/MeetingTranscriber/Sources/PipelineQueue.swift:978-1052,1507-1524`
- `app/MeetingTranscriber/Sources/TerminalJobStore.swift:30-68`
**Optional:**
- `app/MeetingTranscriber/Tests/PipelineQueueMeetingFilesLifecycleTests.swift:1-125` (queue setup, recordings, naming park)
- `app/MeetingTranscriber/Tests/PipelineQueueTests.swift:4190-4233` (a job driven to done with names)

### Key context
- `PipelineQueue.swift` and `PipelineQueue+Stages.swift` are past SwiftLint's `file_length`; put new code in the new extension files.
- `loadSnapshot` discards `.done` jobs and `cancelJob` returns early for `.done` and relocates staged audio: both need the marker (task 3).
- gh-6 (profiles, open, not ready) rewires job configuration and Retry in the same files; whichever builds second rebases.

## Acceptance
- [ ] `rerunJob` on a finished meeting with a record queues a job with the same id, title, app, start time, participants, time first added, mic delay, pauses, template, background and Notion ids, behind a waiting import (queue order test).
- [ ] With stub engines and a temporary folder, the run transcribes and diarizes a recorded call's two tracks separately and parks for naming; every file it writes (draft, transcript, notes, segments, naming files, 16 kHz copies) carries its own stem, and the meeting's current transcript, notes, additional reports and segments file stay byte for byte.
- [ ] It does not move the audio, write a retention registry entry, mark the processed-recordings ledger or rename to the AI title.
- [ ] While it runs, the job and the record carry the marker with the outcome from before, the record's outcome reads in progress, the finished-job entry is unchanged, and `PipelineController.jobStatus(forID:)` answers from the live job.
- [ ] Admission refuses and changes nothing for: a record that is not finished, a pending or incomplete deletion, a marker already present (also one in the record file written outside this queue), a job already live, audio held by another run, audio gone, audio unreachable; the last two say which.
- [ ] After naming is confirmed and the notes are saved, the success hook receives the re-run's files once; confirmed names update voice profiles as any naming does (A9).
- [ ] The Quick commands' focused tests and `./scripts/lint.sh` pass.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
