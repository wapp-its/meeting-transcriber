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
A re-run of a finished meeting can now start from its own run inputs. The meeting's file record keeps the mic delay, pauses, mic mute spans, notes template, background and Notion page with its database (`MeetingFileRecord.runInputs`), and `MeetingFileRecord.rerunInputs(finished:)` returns them, or the fallbacks for a record without them.

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

stage: impl-review - ran [2026-11-15T16:43Z..2026-11-15T16:53Z] (codex gpt-6.1-sol xhigh, three reviewers then one; NEEDS_WORK with one finding, fixed in 65ee1efd, re-review SHIP)

Decisions and assumptions
- Assumption: `MeetingFileRecord(job:origin:createdBy:)` builds the record with the run inputs, so the create in `PipelineQueue.enqueue(_:origin:)` saves them in the same write, after `stampTranscriptOutputOptions` picked the template. Recovered recordings get them through the same initializer (`PipelineQueue+OrphanRecovery.swift` unchanged). The plan named a separate `update` in `enqueue` for an existing record. No enqueue meets one today, since every enqueued job has a new id and Retry does not enqueue, so none was added. Task 2 writes the inputs at re-run admission if it needs them there.
- Review fix: the Notion hook (`noteNotionExport`) writes only the page and its database into kept inputs. A Regenerate Notes on a held job changes the job's template and saves the export state again, and the first version copied that template into the record. A record without run inputs (one an older build rewrote) takes all of them from the job.
- Fallback page: a record without a kept page takes the finished-job entry's export id (`JobStatusDTO.export.id`) with no database. Page and database are written together (`PipelineJob.recordNotionPage`).
- Each field of `RunInputs` decodes when missing (`decodeIfPresent` with defaults), and the record decodes the whole value with `decodeIfPresent`. No new `MeetingFile.Role`.
- The background is stored in the owner-only record file and never logged.

Follow-ups (not built)
- Regenerate Notes on a meeting that has left the queue (`ProtocolRegeneration`) does not write its template into the record, so a re-run uses the template the meeting entered processing with. If a re-run should use the regenerated template, the regeneration would update `runInputs.protocolTemplate`.
- `TranscriptionsViewTests.testSnapshotOfTheRowMenuWithLongReportNames` (open-menu pixel snapshot, skipped on CI) failed once in the 342-test focused gate run and passed alone on the same build. It passed in the baseline run and in an earlier run on this branch. This change does not touch that menu.

Tests
- `MeetingFileStoreTests`: round trip with every field including `runInputs`, a record without the field reads `nil`, `runInputs: {}` reads as the defaults, the resolver's fallbacks one assertion per field, stored values win over the entry, stored inputs without a page take the entry's page.
- `PipelineQueueMeetingFilesRunInputsTests`: a recorded call and an import keep their inputs at entry and the page and normalized database after an export (stub exporter); a record write that fails after the export started leaves the job done with its export completed; a regenerated template on a held job leaves the kept one; an export gives a rewritten record its inputs back.
- `PipelineQueueMeetingFilesEntryTests`: a recovered recording's record holds the inputs taken after admission.
- Each production wiring line was removed once and the tests above failed at it (init, decoder, Notion hook, resolver page fallback).

baseline: green (focused Quick-command set, 334 tests, exit 0; lint green per the conductor)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: ca40a2657288eec1e71757f2ebe082e5541d4f0c, 65ee1efda23a6ed9fc12661a260bd53bd82cd6cc, ffcda9a9e92ebe84d7e289fe225442e0427926d1
- Tests: cd app/MeetingTranscriber && swift build -j 6 --build-tests (exit 0), CFFIXED_USER_HOME=<scratch> swift test --skip-build --parallel --num-workers 2 --filter 'RecordingRowActionsTests|RowAvailabilityTests|MeetingFileStoreTests|PipelineQueueRetryTests|PipelineQueueMeetingFiles|TerminalJobStoreTests|SpeakerNamingStoreTests|LateRerunCancelTests|TranscriptionsViewTests|RegenerateProtocolViewTests|MeetingNotesRetryTests|LocalModelGateWiringTests|ArtifactRenameReportTests|ProtocolRegenerationMeetingFilesTests|MeetingFileStoreReportTests|PipelineQueueNotion|PipelineControllerNotionExportTests|MenuBarNotionRetryTests|PipelineQueueProtocolTemplateTests|PipelineControllerRetentionTests|MeetingFileRemoverTests|PipelineQueueOrphan' (342 run, exit 1: 341 passed, TranscriptionsViewTests.testSnapshotOfTheRowMenuWithLongReportNames open-menu pixel snapshot failed once, CI skips it), swift test --skip-build --filter TranscriptionsViewTests/testSnapshotOfTheRowMenuWithLongReportNames (same build, exit 0), ./scripts/lint.sh with pinned SwiftFormat and SwiftLint (exit 0, 0 violations)
- PRs: