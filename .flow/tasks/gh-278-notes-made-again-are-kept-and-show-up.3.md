---
satisfies: [R2, R9]
---
# gh-278-notes-made-again-are-kept-and-show-up.3 Notes written by a regeneration reach the meeting's row, also after a relaunch

## Description
Makes notes that a regeneration writes for a meeting without notes reach its row, its menus and "Last Recording", and keeps them there after a relaunch, for a job in the queue and for a meeting known only from the history, without moving the meeting in the history (R2, A5, A9). It uses `clearNotesFailure(at:)` and the not-written warning list as .2 leaves them, and the run of .1.

**Size:** M
**Files:** `Sources/ProtocolRegeneration.swift`, `Sources/ProtocolRegenerationTarget.swift`, `Sources/AppState.swift`, a new `Sources/PipelineQueue+RegeneratedNotes.swift`, `Sources/PipelineQueue+Notion.swift`, `Sources/TerminalJobStore.swift`, `docs/architecture/pipeline.md`; tests `Tests/ProtocolRegeneratorTests.swift`, `Tests/ProtocolRegenerationTargetTests.swift`, `Tests/TerminalJobStoreTests.swift`, a new `Tests/PipelineQueueRegeneratedNotesTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/ProtocolRegeneration.swift, app/MeetingTranscriber/Sources/ProtocolRegenerationTarget.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/PipelineQueue+RegeneratedNotes.swift, app/MeetingTranscriber/Sources/PipelineQueue+Notion.swift, app/MeetingTranscriber/Sources/PipelineQueue+MeetingNotes.swift, app/MeetingTranscriber/Sources/PipelineQueue.swift, app/MeetingTranscriber/Sources/TerminalJobStore.swift, app/MeetingTranscriber/Tests/ProtocolRegeneratorTests.swift, app/MeetingTranscriber/Tests/ProtocolRegenerationTargetTests.swift, app/MeetingTranscriber/Tests/TerminalJobStoreTests.swift, app/MeetingTranscriber/Tests/PipelineQueueRegeneratedNotesTests.swift, docs/architecture/pipeline.md]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first: the queue test for a held job with failed notes and the history-order test fail on today's code.
1. **Hook.** Add `notesWritten: (UUID, URL) -> Void` to `ProtocolRegenerator.Environment` with a no-op default (the style at `Sources/ProtocolRegeneration.swift:163-177`, so the many test call sites still compile), called in the branch that already calls `regenerated` and `notesReplaced` (`:265-268`, main notes written for a target with a job id). Wire it in `AppState.makeProtocolRegenerator` (`Sources/AppState.swift:170-185`) to the queue step below; keep the factory's explicit types (the `AppState.init` type-check budget).
2. **Every route has the job id.** The row (`target(for:)` from the entry, `Sources/ProtocolRegeneration.swift:205-235`) and a notice's Try Again (`tryAgain`, `:521-531`) have it. "Regenerate from File…" (`ProtocolRegenerationTarget.resolve`, `Sources/ProtocolRegenerationTarget.swift:103-128`, called at `Sources/ProtocolRegeneration.swift:205-210`) looks only at the history, and a held job can outlive its record (the comment at `:211-216`). Give `resolve` the queue's jobs too, matched by their transcript or notes path like the records, the queued job first.
3. **Queue step**, for example `PipelineQueue.recordNotesWrittenByRegeneration(jobID:path:)`, not guarded by `liveJobIndex`:
   - a finished job in the queue: set `protocolPath`, `clearNotesFailure(at:)`, save the snapshot, then write its history record: in place when it has one, a new record at the end when the cap dropped it (A9). Once the job is no longer `isHeldAfterCompletion`, call `scheduleCompletedJobRemoval(id:)` (`Sources/PipelineQueue.swift:1150`), which a held job never had (pattern `Sources/PipelineQueue+MeetingNotes.swift:39-45`);
   - a meeting only in the history: rewrite that record's notes path in place and drop the warnings on .2's list;
   - neither: nothing.
4. **History in place** (`Sources/TerminalJobStore.swift`): a replace by job id that keeps the record's index. `upserting` (`:38-47`) drops and appends, which makes the meeting "Last Recording" (`TranscriptionList.lastFinished` ranks by index, `Sources/TranscriptionList.swift:170,227`). `TerminalJobRecord` and `JobStatusDTO` have only `let` fields, so build the new record from the old one. The `regenerated` hook's own history write (`recordRegeneratedTemplate` → `persistNotionExportChange` → `recordTerminalJob`, `Sources/PipelineQueue+Notion.swift:434-452`) also moves the record when the template changed; route the regeneration's history writes, template and notes path, through the in-place replace, for example by letting the queue step record both in one write. Notion's own export writes keep `recordTerminalJob` as they are.
5. **Failed writes**: a snapshot or history write that fails is logged without content and does not fail the regeneration.
6. **Docs**, in the same change: `docs/architecture/pipeline.md` failed-notes paragraph (`:48`): notes written by a regeneration also clear the failure, reach the row and keep the meeting's place in the history.

Tests:
- Regenerator (pattern `Tests/ProtocolRegeneratorTests.swift:339`, `makeRegenerator(regenerated:notesReplaced:)` at `:72-97`): main notes for a target with a job → `notesWritten(jobID, path)` once; an additional report → not called; a file neither the queue nor the history names → not called.
- Target (`Tests/ProtocolRegenerationTargetTests.swift`): a file of a queued job without a history record resolves to that job's id; with both, the queued job wins.
- Queue (pattern `Tests/PipelineQueueNotionTitleTemplateTests.swift:119-150`, `insertJobForTesting`): a held `.done` job with `notesFailure` and the low-memory detail → `protocolPath` is the new path; failure, detail and the listed warnings are gone; it is no longer in `jobsWithRetryableMeetingNotes`; its removal is scheduled; the saved snapshot has the path.
- History order, through the wired step with a changed template: an older finished meeting in the queue, a newer finished meeting after it → after the regeneration both records keep their places and `lastFinished` is still the newer meeting.
- A job in the queue without a history record: after the step the history has a new record at the end with the notes path.
- Relaunch: a `.done` job without a failure is not restored from the snapshot (`Sources/PipelineQueue+Recovery.swift:87-92,150`, by design), so after the removal and a reload of the store, the `TranscriptionList` built from the restored queue and the reloaded history shows the meeting with its notes path, for the row route and the "Regenerate from File…" route, and for a meeting known only from the history (`Tests/TerminalJobStoreTests.swift:95` for the reload).
- Store (pure): the in-place replace keeps order and the cap; an unknown id changes nothing.
- Wiring: a test fails when the `notesWritten` line in `AppState.makeProtocolRegenerator` is removed (check at that line, per `CONTRIBUTING.md`, Tests).

### Investigation targets
**Required** (read before coding):
- `Sources/ProtocolRegeneration.swift:160-270` — `Environment`, target lookup, the success branch
- `Sources/ProtocolRegenerationTarget.swift:95-130` — `resolve`
- `Sources/PipelineQueue+Notion.swift:430-455` — `recordRegeneratedTemplate`, `persistNotionExportChange`
- `Sources/PipelineQueue.swift:1100-1170` — `updateJobState`, `scheduleCompletedJobRemoval`, `recordTerminalJob`
- `Sources/TerminalJobStore.swift:30-60` — `upserting`, save and load

**Optional** (reference as needed):
- `Sources/PipelineQueue+Recovery.swift:80-155` — which jobs a relaunch restores
- `.flow/memory/bug/data/a-meetings-file-record-assumed-what-a-2026-11-06.md` — record what the write did, not what a later look suggests

### Key context
- The step runs on the main actor like the other queue mutations; the history write goes through the store's existing save path.
## Acceptance
- [ ] Main notes written by a regeneration for a meeting in the queue set its notes path, clear its failure, detail and not-written warnings, take it out of "Needs you", and schedule its removal; the saved snapshot has the path.
- [ ] The regeneration's history writes (template and notes path) keep the record's place, so "Last Recording" does not change; a queued job whose record the cap dropped gets a new record at the end.
- [ ] "Regenerate from File…" on a queued job's file finds that job; after a relaunch the row shows the notes from the history, for the row route, the file route and a history-only meeting.
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
