---
satisfies: [R1, R11]
---
# gh-171-transcribe-again-and-identify-speakers.1 Keep each meeting's run inputs in its record

## Description
Adds the run inputs a re-run needs to the meeting's record (R1, A13, A20), written when a job enters processing and after its Notion export, plus the pure fallback for a record without them. First because every later task rebuilds a job from these fields.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/MeetingFileRecord.swift`, `app/MeetingTranscriber/Sources/MeetingFileStore.swift`, `app/MeetingTranscriber/Sources/PipelineQueue.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+Notion.swift`, a new `app/MeetingTranscriber/Sources/MeetingFileRecord+RunInputs.swift`, tests
**Touches:** [app/MeetingTranscriber/Sources/MeetingFileRecord*.swift, app/MeetingTranscriber/Sources/MeetingFileStore.swift, app/MeetingTranscriber/Sources/PipelineQueue.swift, app/MeetingTranscriber/Sources/PipelineQueue+Notion.swift, app/MeetingTranscriber/Tests/MeetingFileStoreTests.swift, app/MeetingTranscriber/Tests/PipelineQueueMeetingFiles*.swift]

### Approach
- One optional value on `MeetingFileRecord` holding mic delay, pauses (`RecordingPause`), the mic's muted stretches (`PipelineJob.micMuteIntervals`, `[MicMuteInterval]` on the mic track's timeline; in the fork since the 2026-11-15 upstream merge, so A20 applies), protocol template (`ProtocolTemplateID`), background, Notion database and page ids. Decode it with `decodeIfPresent` in the custom `init(from:)` (`MeetingFileRecord.swift:115-131`); add it after `createdBy` with a nil default, since tests call the memberwise init positionally.
- Write it from the job in `PipelineQueue.enqueue(_:origin:)` (`PipelineQueue.swift:753-764`) after `stampTranscriptOutputOptions` (789-803) picked the template. `MeetingFileStore.create` keeps an existing record (64-71), so this is an `update`.
- Add the Notion ids where the export already reports to the record (`persistNotionExportChange` / `noteNotionExport`, `PipelineQueue+Notion.swift:401-413`), after `recordNotionPage` (283, 397).
- A pure resolver returns what a re-run uses: the stored values, else no mic delay, no pauses, no mute spans, no template (the rules pick one by title), no background, and the page id from the finished-job entry (`TerminalJobRecord.status`, `JobStatusDTO` export id).
- No new `MeetingFile.Role` (API Contracts): roles decode strictly in an older build.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/MeetingFileRecord.swift:11-131` (fields, decoder, `init(job:origin:createdBy:)`)
- `app/MeetingTranscriber/Sources/MeetingFileStore.swift:60-90` (create, update)
- `app/MeetingTranscriber/Sources/PipelineQueue.swift:749-803` (enqueue, template stamp)
- `app/MeetingTranscriber/Sources/PipelineQueue+Notion.swift:395-415`
**Optional:**
- `app/MeetingTranscriber/Tests/MeetingFileStoreTests.swift:41-58,120-132` (round trip, decode without fields)
- `app/MeetingTranscriber/Tests/PipelineQueueMeetingFilesTests.swift:115-149` (hook tests)
- `app/MeetingTranscriber/Sources/PipelineJob.swift:82-84,415,436,457-461` (`micMuteIntervals`, `micMuteSpansOnTranscript`)

### Key context
- Capture the inputs from the job when it enters processing, never from Settings later (memory: a job's outcome read a setting that changed during the protocol call).
- A failed record write is logged and does not fail the job, as for every gh-97 hook.
- The background is text the user wrote: log it only as a private value, like the template name.

## Acceptance
- [ ] A record written for a new recorded call and for an import holds its mic delay, pauses, mute spans (A20), template and background; after a Notion export it also holds the page and database ids (pipeline test with a stub exporter).
- [ ] A record file without the new fields decodes with them absent, and a full round trip keeps them (`MeetingFileStoreTests`).
- [ ] The resolver returns each fallback of Architecture for a record without the fields, one assertion per field, and the stored value when present.
- [ ] A record write that fails is logged and leaves the job's state and outcome unchanged.
- [ ] No new `MeetingFile.Role`; a record file written before this task still reads.
- [ ] The Quick commands' focused tests and `./scripts/lint.sh` pass.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
