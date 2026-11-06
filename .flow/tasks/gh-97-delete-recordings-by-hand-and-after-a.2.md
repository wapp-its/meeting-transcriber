---
satisfies: [R1, R13]
---
# gh-97-delete-recordings-by-hand-and-after-a.2 Meeting file record: imports, recovery, retry, cancel, naming files, Regenerate Protocol and the segments permission

## Description
Completes the record of task .1 for every other way a meeting enters, leaves or changes: imports, orphan recovery, retry, cancel, dismiss and remove, the naming files that come and go, the raw transcript removal, and Regenerate Notes. Also R13: the segments file is written owner-only. Split from task .1 so the proof point stays small; these are many small hooks at known choke points.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/PipelineQueue.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+Notion.swift`, `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift`, `app/MeetingTranscriber/Sources/SpeakerNamingSession+Late.swift`, `app/MeetingTranscriber/Sources/SpeakerNamingStore.swift`, `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift`, `app/MeetingTranscriber/Sources/AppState.swift`, `app/MeetingTranscriber/Sources/MeetingFileStore.swift`, `app/MeetingTranscriber/Tests/PipelineQueueMeetingFilesTests.swift`, `app/MeetingTranscriber/Tests/ProtocolRegenerationMeetingFilesTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/PipelineQueue.swift, app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift, app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift, app/MeetingTranscriber/Sources/PipelineQueue+Notion.swift, app/MeetingTranscriber/Sources/SpeakerNamingSession.swift, app/MeetingTranscriber/Sources/SpeakerNamingSession+Late.swift, app/MeetingTranscriber/Sources/SpeakerNamingStore.swift, app/MeetingTranscriber/Sources/ProtocolRegeneration.swift, app/MeetingTranscriber/Sources/MeetingFileStore.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Tests/PipelineQueueMeetingFilesTests.swift, app/MeetingTranscriber/Tests/ProtocolRegenerationMeetingFilesTests.swift]

### Approach
- **Orphan recovery** (`PipelineQueue+Recovery.swift:441`, the job is appended at `:505` without `enqueue`): create the record there as `.recorded` (orphans are only scanned in the staging folder, which only the recorder writes); its recording date falls back to `enqueuedAt` by task .1's rule (A6). Recovery also admits staging recordings left from before an upgrade, so compare the audio file's creation date with the store's `since`: when it is earlier, set `excludedFromAutomaticDeletion` (spec "Recordings from before this feature", D9). The manual actions still apply to it.
- **Outcome changes**:
  - `cancelJob` (`PipelineQueue.swift:656`) on a job that is not terminal: `.leftUnfinished`.
  - `removeJob` (`PipelineQueue.swift:621`): `.leftUnfinished` only while the outcome is still `.inProgress`. The queue also calls `removeJob` to reap a finished job after `completedJobLifetime` (`:747-751`), and that must keep `.finished`; a failed job removed through `removeFailedJob` (`PipelineController+Transcriptions.swift:40`) stays `.failed`.
  - `retryJob` (`PipelineQueue+Recovery.swift:377`): back to `.inProgress`, same record, recording date and Keep unchanged, `incomplete` and `audioDeletion` untouched.
- **Rewrites of listed files** (task .1's `noteWritten` helper, so the stored identity follows each atomic replace): the transcript rewritten when speaker names are confirmed (`SpeakerNamingSession+Late.swift:74`) and by a late re-diarization (`SpeakerNamingSession+Late.swift:394`, reached through `rewriteTranscriptFromLateRun` at `:213`); `_naming.json` on every save (`SpeakerNamingStore.swift:86`), not only the first. The writers task .1 already covers are the transcript draft and final transcript (`PipelineQueue+Stages.swift:141`, `:856`), the segments file (`:897`) and the protocol (`:978`); Regenerate Notes is below. Report these through the same session callback as the naming files.
- **Naming files**: list `_naming.json` when `saveNamingData` writes it (`SpeakerNamingSession.swift:396`, also reached from `:343` and `SpeakerNamingSession+Late.swift:204`); after `removeNamingData` (`SpeakerNamingSession.swift:460`, which runs `cleanupSidecarFiles`, `SpeakerNamingStore.swift:145`) mark the naming file, the 16 kHz copies and the segments file gone where the file is gone. The session and the naming store are keyed by slug and know nothing of records, so do not thread the record store into them: give the session one callback (`onNamingFilesChanged: (UUID) -> Void` or similar) the queue wires, and let the queue re-check those roles for that job. `cleanupStalePending` (`SpeakerNamingSession.swift:544`) and the late paths reach the same removal, so the callback covers them.
- **Notion export** (`PipelineQueue+Notion.swift`): the record's `savedToNotion` mirrors the job's `hasCompletedNotionExport`. Copy it in `persistNotionExportChange`, which every export step passes through, and in `queueNotionExport`, which begins a re-export without it, so a re-export that fails or is interrupted takes the mark back. `recordNotionPageExport` must not set it on its own: `NotionClient` calls it when the page is created, before the rest of the content is appended, while the status is still in progress. `removeLocalProtocol` removes the protocol file after a successful export: mark it gone. Regenerating the notes later lists the new file as usual and leaves `savedToNotion` set, since no export ran and the page still exists.
- **Cancelled recording**: `relocateRecordingOfCancelledJob` (`PipelineQueue+Stages.swift`, new since this plan was reviewed) moves a cancelled job's recording; the record follows the new paths, so a later Trash action finds them.
- **Raw transcript removal**: `removeRawTranscriptArtifactsIfSafe` (`PipelineQueue.swift:~765-800`) deletes the `.txt` and the segments when "save raw transcript separately" is off; mark both gone.
- **Regenerate Notes** (`ProtocolRegeneration.swift:440`, `replaceProtocol`): when its target carries a `jobID` (`:108`), report the new protocol URL and, if the Trash refused the old one and it was kept as `.previous-<stamp>.md`, that kept file, through a closure added to `ProtocolRegenerator.Environment` and wired to the record store in `AppState.makeProtocolRegenerator` (`AppState.swift:152-195`). The record lists the protocol with its new identity (also for a meeting that had none) and the kept previous copy as owned `.previousProtocol`, so Move Meeting to Trash takes it too. A target without a `jobID` (a file chosen by hand) changes no record.
- **R13**: after the atomic write of `_segments.json` (`PipelineQueue+Stages.swift:895-897`) call `FileManager.restrictToOwner` (`FileManager+OwnerOnly.swift`), best effort like the write itself. Older segments files are not touched.
- **Gone versus unreachable**: whenever a hook marks a file gone, ask task .1's `MeetingFilePresence`; only `.gone` marks it gone.
- **Tests, written first**, extending `PipelineQueueMeetingFilesTests`: an import enqueued through `PipelineController.enqueueFiles` records origin imported, its source not owned and no recording date, also for a source file placed inside `<output>/recordings`; an orphan recording gets a record with recording date `enqueuedAt`; an orphan whose audio file was created before the store's `since` (the upgrade-after-crash case) is excluded from automatic deletion, one created after it is not; cancel of a waiting job gives `.leftUnfinished`; the reaper's `removeJob` after done keeps `.finished`; dismissing a naming-pending job gives `.leftUnfinished` and marks the naming files gone; retry returns `.inProgress` with the recording date unchanged; with "save raw transcript separately" off the transcript and segments are gone after done; the segments file has permissions 0600; after speaker names are confirmed, and after a late re-diarization, the record's transcript identity equals the identity of the file now on disk, and so does the naming file's after a second save; an export that creates its page and then fails leaves `savedToNotion` off, a completed one sets it and keeps it when the local file goes, and a later export that fails takes it back. `ProtocolRegenerationMeetingFilesTests`: regenerating for a job id updates the protocol path, a refused Trash adds the kept previous copy, and a hand-picked file changes no record.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/PipelineQueue.swift:621-690` - `removeJob`, `cancelJob`
- `app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift:377-400` and `:441-510` - retry and orphan recovery
- `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift:380-470` - saving and removing naming data
- `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift:400-500` - `replaceProtocol`, `withOutputScope`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/SpeakerNamingStore.swift:40-60`, `:140-167` - sidecar suffixes and cleanup
- `app/MeetingTranscriber/Sources/PipelineController.swift:400-480` - the import entry points

### Key context
- Dismiss already deletes the 16 kHz copies and the segments; the record must follow that, not assume they exist.
- A paired import without a `_mix.wav` mixes into the temporary work folder, which is never persisted: list only files that exist at their recorded path.
## Acceptance
- [ ] An imported file gets a record with origin imported, its source not owned (also inside the recordings subfolder) and no recording date; a recovered orphan gets a record with the time it entered processing as its recording date, and one whose audio predates this feature is excluded from automatic deletion (R1, A6, D9).
- [ ] Cancel, dismiss and remove of an unfinished job give the outcome "left unfinished"; the queue's reaping of a finished job keeps "finished"; Retry returns "in progress" without changing the recording date or the Keep mark (R1, spec "Meeting outcome").
- [ ] The record lists the naming file while it exists and marks the naming file, 16 kHz copies, segments and (with the raw transcript option off) the transcript gone once the pipeline removed them (R1).
- [ ] Every app rewrite of a listed file (transcript on confirmed names and on a late re-diarization, each save of the naming file, the protocol) updates the file's recorded identity, so the app never later refuses its own file as replaced (R1, spec "Same file, right before removal").
- [ ] Regenerate Notes for a meeting updates its protocol path and lists a previous protocol the Trash refused; a hand-picked file changes no record (R1).
- [ ] The segments file is written with permissions 0600; older segments files keep theirs (R13).
- [ ] A completed Notion export sets the record's saved-to-Notion mark, and removing the local file afterwards marks the protocol gone without losing that mark; an export that created its page and then failed does not set it, and a later export that fails takes it back; a cancelled recording's record lists its relocated paths (R1, A8).
- [ ] The new tests were written before the implementation and pass; the spec's quick command stays green.
## Done summary
A meeting's file record now follows it through imports, orphan recovery, Retry, cancel, dismiss and remove, speaker naming, raw transcript removal, Notion exports, a cancelled recording's move and Regenerate Notes, so a later deletion finds every file and never refuses the app's own file as replaced. New segments files are written with permissions 0600 and older ones keep theirs.

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

baseline: green via handoff (green (verified at 6358433e by the conductor; only .flow/ paths moved since))
gate classify: FULL (code changed), so the focused Quick commands ran: 49 tests in the new and the existing meeting file classes on the committed tree, 791 neighbouring pipeline, naming, regeneration, Notion, controller and workflow tests, the spec's quick command (101 tests), all exit 0; lint 0 violations.

Not run here: the App Store variant build, CI's `swiftlint analyze`, the full suite and the sanitizers. The new code has no `#if` and uses nothing the App Store variant lacks, but no build has checked that.

Tests written first: 22 of the 32 new tests ran red against compile-only stubs, each because the record did not change yet. The other 10 passed from the start, because they pin what must stay as it is: the three import tests (task .1's `enqueue` default already records them, so this task adds no import code), removing a failed job, a folder that is not there, a transcript kept after a failed protocol, an older segments file, a page created before a failed export, a hand-picked file, a job without a record. Of those 10 only the missing-folder test was checked by hand: with the probe swapped for `fileExists` it went red.

### Deviations from the task text

DECIDED: `PipelineQueueMeetingFilesTests.swift` stays unchanged and the new queue tests sit in `PipelineQueueMeetingFilesLifecycleTests.swift` and `PipelineQueueMeetingFilesEntryTests.swift`, because adding them there broke `type_body_length` at 452 lines (rule 1: the brief's split rule, these two files count as inside Touches).
DECIDED: Retry returns "in progress" from `noteOutcome` in `PipelineQueue.swift`, because `retryJob` moved to `PipelineQueue+Retry.swift`, outside Touches. Only a Retry enters `.waiting` as a state change, so the case needs no check of the old state (rule 6). The task's other line references were stale as well and were resolved by name.
DECIDED: `SpeakerNamingStore.save` keeps its signature and a new `namingFile(slug:)` names the path, instead of `save` returning it. `saveNamingData` reports from a `defer`, because a refused chmod throws after the write has already replaced the file (rule 6).

### Other choices

DECIDED: a job the restore discards for its missing audio also gets "left unfinished", or it would read as in progress for good. The in-flight drop right below it does not, because another queue still runs that job (rule 6).
DECIDED: an orphan whose mix has no readable creation date counts as older than the store and is excluded from automatic deletion (rule 1: spec D9, the safe side).
DECIDED: when neither the new protocol nor the old one could go in place, the record lists the kept copy and marks the protocol gone (rule 6).
DECIDED: a queued Notion re-export turns the mark off at once, because a quit before it runs ends it failed without passing `exportToNotion` (rule 1: spec "the meeting's latest Notion export completed").
DECIDED: `ProtocolRegenerator.environment` loses `private`, so one test can tell a wired `protocolReplaced` from its do-nothing default (rule 6).
DECIDED: the new `protocolReplaced` closure follows `regenerated` and `AppState` passes the store's method. `regenerated` is then no longer the last argument, so its `trailing_closure` disable comment is gone (rule 6).

### Known limits

A refused chmod on the segments file leaves it with default permissions and no warning (`try?`), the same silence a failed write of this optional file already has. Volumes that refuse chmod can do this.

### For later tasks

`previousProtocol` is the one role that can list several files, added by `MeetingFileStore.noteProtocolReplaced`. The doc comment on `MeetingFileRecord.list` still says a role has one file, which holds for every caller of `list`; that file is outside this task's Touches. Code that reads files by role has to expect several here.

This task sets `excludedFromAutomaticDeletion` and `savedToNotion`, which the deletion decision reads later. Both are declared by task .1 and no production code reads them yet. The Notion mark ignores a retired queue, like the terminal job store next to it.

No route a user takes to a mapped feature changed.

stage: impl-review - ran (model: gpt-6-astra xhigh (codex:gpt-6-astra:xhigh)); verdict SHIP after 2 round(s)
DECIDED: finding 1 (P1, the correctness reviewer reproduced it, validator kept it, status now fixed) reverses the worker's deviation "`saveNamingData` reports from a `defer`": `SpeakerNamingStore.save` now hands the path to an `onWritten` closure between the write and the chmod, and `namingFile(slug:)` is gone. A refused chmod still reports the rewrite, a failed write reports nothing (rule 1: spec "Same file, right before removal"; rule 6 for the closure). The worker's summary line is out of date on this point.
DECIDED: finding 2 (P2, the integration reviewer reproduced it on the naming file, validator kept it, status now fixed) is fixed at its cause in the shared listing hook for every role, not for the naming file alone, because the transcript, segments, 16 kHz copies and protocol lose their entries the same way (rule 1: spec "Reachable versus gone" and "It lists every file the meeting has"). This changes `MeetingFileRecord.swift`, outside the task's Touches, because `list` is where the cause sits.
DECIDED: this replaces the worker's note for later tasks: any role can now list several files, not only `previousProtocol`, and an entry leaves only when the presence probe answers gone. Code reading by role has to expect several; tasks .3 and .4 as planned filter by role and state, so their text needs no change (rule 6).
DECIDED: the probe runs on the main actor outside the lock, as `markGone` already does, and only when an entry of the role sits at another path, so a write to the same path costs no probe (rule 6).
FOLLOW-UP: PipelineQueue+Stages `moveCopy` (from task .1, spec gh-97) reports a 16 kHz copy whenever a file sits at its destination, also when the move failed, so a symbolic link placed there would be listed by its target as owned. Matters if such a link can appear in the recordings folder before stage 3; the spec accepts changes by someone with write access to that folder.
FOLLOW-UP: SpeakerNamingStore.save (spec gh-97): the branch where the chmod is refused after the write landed has no test, as a normal volume cannot be made to refuse it. Matters if a regression there would otherwise go unseen on a volume that refuses chmod.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: b8dbd497d294a270b0902465bef53ddb3133107e, 2cf9b8398c80ae125356b5626786499eb1a68a34, e4fb6634254df5144aa81a6c280bc87ad971a657, 20f845fa60087ac18a1eb58180750aca6fc50325
- Tests: CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'PipelineQueueMeetingFilesEntryTests|PipelineQueueMeetingFilesLifecycleTests|ProtocolRegenerationMeetingFilesTests|PipelineQueueMeetingFilesTests' (exit 0, 49 tests, on the committed tree), CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'PipelineQueue|SpeakerNaming|LateRerun|NamingSidecar|ProtocolRegenerat|CancelledJob|WorkflowIntegration|NotionExport|MenuBarNotionRetry|AppStateTests|StagedRecovery|MeetingFile|TerminalJob|PipelineController' --skip 'ModelPreloadTests|ParakeetE2ETests|LiveTranscriptionE2ETests|LiveCaptionPipelineTests|EouStreamingE2ETests|WatchLoopE2ETests' (exit 0, 791 tests), CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'TranscriptionsViewTests|TranscriptionListTests|RecordingRowActionsTests|RowAvailabilityTests|PipelineControllerTranscriptionsTests|TranscriptionsWindowPrivacyTests|TerminalJobStoreTests|TerminalJobRecordTests|AudioPersistencePolicyTests|OutputSettingsViewTests|SpeakerNamingStoreTests|ProcessedRecordingsLedgerTests' (the spec's quick command, exit 0, 101 tests), ./scripts/lint.sh (exit 0, 0 violations)
- PRs: