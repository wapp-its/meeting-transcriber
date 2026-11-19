---
satisfies: [R2, R9]
---
# gh-278-notes-made-again-are-kept-and-show-up.3 Notes written by a regeneration reach the meeting's row, also after a relaunch

## Description
Makes notes that a regeneration writes for a meeting without notes reach its row, its menus and "Last Recording", and keeps them there after a relaunch, for a job in the queue and for a meeting known only from the history (R2, A5). It uses `clearNotesFailure(at:)` as .2 extends it, and the run of .1.

**Size:** M
**Files:** `Sources/ProtocolRegeneration.swift`, `Sources/AppState.swift`, a new `Sources/PipelineQueue+RegeneratedNotes.swift` (or `Sources/PipelineQueue+MeetingNotes.swift`), `Sources/TerminalJobStore.swift`, `docs/architecture/pipeline.md`; tests `Tests/ProtocolRegeneratorTests.swift`, `Tests/TerminalJobStoreTests.swift`, a new queue test file
**Touches:** [app/MeetingTranscriber/Sources/ProtocolRegeneration.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/PipelineQueue+RegeneratedNotes.swift, app/MeetingTranscriber/Sources/PipelineQueue+MeetingNotes.swift, app/MeetingTranscriber/Sources/PipelineQueue.swift, app/MeetingTranscriber/Sources/TerminalJobStore.swift, app/MeetingTranscriber/Tests/ProtocolRegeneratorTests.swift, app/MeetingTranscriber/Tests/TerminalJobStoreTests.swift, app/MeetingTranscriber/Tests/PipelineQueueRegeneratedNotesTests.swift, docs/architecture/pipeline.md]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first: the queue test for a held job with failed notes fails on today's code.
1. **Hook.** Add `notesWritten: (UUID, URL) -> Void` to `ProtocolRegenerator.Environment` with a no-op default (the style at `Sources/ProtocolRegeneration.swift:163-177`, so the many test call sites still compile), called in the branch that already calls `regenerated` and `notesReplaced` (`:265-268`, main notes written for a target with a job id). Every path R2 lists reaches that branch with a job id: the row (`target(for:)` from the entry, `:215-235`), "Regenerate from File…" (`ProtocolRegenerationTarget.resolve`, the newest history record naming the meeting's files, `Sources/ProtocolRegenerationTarget.swift:103-128`) and a notice's Try Again (`tryAgain`, `:521-531`). Wire it in `AppState.makeProtocolRegenerator` (`Sources/AppState.swift:170-185`) to the queue step below; keep the factory's explicit types (the `AppState.init` type-check budget).
2. **Queue step**, for example `PipelineQueue.recordNotesWrittenByRegeneration(jobID:path:)`, not guarded by `liveJobIndex` (unlike `recordRegeneratedTemplate`, `Sources/PipelineQueue+Notion.swift:434-452`):
   - a finished job in the queue: set `protocolPath`, `clearNotesFailure(at:)`, save the snapshot, rewrite its history record in place; once the job is no longer `isHeldAfterCompletion`, call `scheduleCompletedJobRemoval(id:)` (`Sources/PipelineQueue.swift:1150`), which a held job never had (pattern `Sources/PipelineQueue+MeetingNotes.swift:39-45`);
   - a meeting only in the history: rewrite that record's notes path in place and drop the same stale warnings;
   - neither: nothing.
3. **History in place** (`Sources/TerminalJobStore.swift`): a replace by job id that keeps the record's index. `upserting` (`:38-47`) drops and appends, which would make the meeting "Last Recording" (`TranscriptionList.lastFinished` ranks by index, `Sources/TranscriptionList.swift:170,227`). `TerminalJobRecord` and `JobStatusDTO` have only `let` fields, so build the new record from the old one.
4. **Failed writes**: a snapshot or history write that fails is logged without content and does not fail the regeneration.
5. **Docs**, in the same change: `docs/architecture/pipeline.md` failed-notes paragraph (`:48`): notes written by a regeneration also clear the failure and reach the row.

Tests:
- Regenerator (pattern `Tests/ProtocolRegeneratorTests.swift:339`, `makeRegenerator(regenerated:notesReplaced:)` at `:72-97`): main notes for a target with a job → `notesWritten(jobID, path)` once; an additional report → not called; a file no record names (no job id) → not called.
- Queue (pattern `Tests/PipelineQueueNotionTitleTemplateTests.swift:119-150`, `insertJobForTesting`): a held `.done` job with `notesFailure` and the low-memory detail → after the step `protocolPath` is the new path; failure, detail and stale warnings are gone; it is no longer in `jobsWithRetryableMeetingNotes`; its removal is scheduled; a queue built again from the saved snapshot has the path (the relaunch).
- History only: the record gets the path and keeps its index; `lastFinished` is unchanged; a store loaded again from disk keeps both (`Tests/TerminalJobStoreTests.swift:95`).
- Store (pure): the in-place replace keeps order and the cap; an unknown id changes nothing.
- The row: the `TranscriptionEntry` built from the queue and from the history has the new `protocolURL`.
- Wiring: a test fails when the `notesWritten` line in `AppState.makeProtocolRegenerator` is removed (check at that line, per `CONTRIBUTING.md`, Tests).

### Investigation targets
**Required** (read before coding):
- `Sources/ProtocolRegeneration.swift:160-270` — `Environment`, the success branch
- `Sources/AppState.swift:165-190` — `makeProtocolRegenerator`
- `Sources/PipelineQueue+Notion.swift:430-455` — `recordRegeneratedTemplate`, `persistNotionExportChange`
- `Sources/PipelineQueue.swift:1100-1170` — `updateJobState`, `scheduleCompletedJobRemoval`, `recordTerminalJob`
- `Sources/TerminalJobStore.swift:30-60` — `upserting`, save and load

**Optional** (reference as needed):
- `Sources/PipelineController+Summaries.swift:17` — `notesSaved`, which the summary already uses
- `.flow/memory/bug/data/a-meetings-file-record-assumed-what-a-2026-11-06.md` — record what the write did, not what a later look suggests

### Key context
- The step runs on the main actor like the other queue mutations; the history write goes through the store's existing save path.

## Acceptance
- [ ] Main notes written by a regeneration for a meeting in the queue set its notes path, clear its failure, detail and stale warnings, take it out of "Needs you", and schedule its removal; a queue restored from the snapshot keeps the path.
- [ ] For a meeting known only from the history, its record gets the path and keeps its place, so "Last Recording" does not change; this holds after the store is loaded again.
- [ ] An additional report and a file without a job change no row; a failed snapshot or history write is logged without content and does not fail the regeneration.
- [ ] The hook is wired in `AppState`, and a test fails without that line.
- [ ] `docs/architecture/pipeline.md` describes the new step.
- [ ] Each new or changed test fails on the code before this task.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
