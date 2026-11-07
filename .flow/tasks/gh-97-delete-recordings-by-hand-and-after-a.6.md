---
satisfies: [R11, R12, R14]
---
# gh-97-delete-recordings-by-hand-and-after-a.6 Automatic deletion: the check and when it runs

## Description
The automatic deletion: a controller that runs task .4's rule over every record and deletes what it returns for good through task .3's mover, at launch, after each finished meeting, once a day, and on request after a setting change. It runs headless, so it can ship and be tested before the Settings section (task .7) exists; with the setting at its default Never it deletes nothing.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/RecordingRetentionController.swift` (new), `app/MeetingTranscriber/Sources/AppState.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/PipelineController.swift`, `app/MeetingTranscriber/Sources/MeetingFileStore.swift`, `app/MeetingTranscriber/Tests/RecordingRetentionControllerTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/RecordingRetentionController.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/PipelineController.swift, app/MeetingTranscriber/Sources/MeetingFileStore.swift, app/MeetingTranscriber/Tests/RecordingRetentionControllerTests.swift]

### Approach
- **Shape**: `@MainActor @Observable final class RecordingRetentionController` modelled on `RemoteVocabularyController` (`RemoteVocabularyController.swift:55-95`): injected `interval: Duration` (one day), `now: () -> Date`, `calendar: Calendar` (carries the time zone), the record store, the live-state lookup (`(UUID) -> LiveMeetingState?`, task .4's type, from the queue's jobs), the row lookup (`(UUID) -> Bool`, whether the queue or `TerminalJobStore` still lists the meeting), the settings, and the mover. `start()` is idempotent (guarded like `:76`), runs one check, then loops on `Task.sleep(for: interval)`; `Task.sleep` keeps counting through system sleep, which is what a daily check wants (`LivenessMarker.swift:84` explains the difference).
- **`requestCheck(after: Duration = .zero)`**: coalesces requests; at most one check runs at a time (`SingleFlight`, `SingleFlight.swift`, or one in-flight task plus a pending flag). Task .7 calls it with a few seconds' delay after a confirmed setting change (R12's "within a minute").
- **One check**: `reload()` the store (the other build may have changed it), read `settings.recordingRetention` once; for each record ask `RecordingRetentionRule.audioToDelete(record:live:retention:now:)`; right before deleting a meeting's files re-read its record and live state and skip it if either changed (a Retry, a reopened naming, a Keep, an export that started); save a pending deletion of kind automatic (task .3; skip the meeting if that save fails), delete through the mover in `.forGood` mode inside the output folder's scope (as task .3 does, never on `.fallback`); on success set `audioDeletion = automatic(at: now)`. A file that is unreachable or cannot be deleted is logged (no file names at `.public` privacy), stays listed, and is tried again at the next check; it does not set the row's incomplete state, which is for manual deletions, and the pending mark is cleared when the meeting is done. A meeting with a pending deletion of another live process is skipped, so two running builds never delete the same meeting at once.
- **Record pruning**: a record none of whose files is present any more, whose folders are reachable and whose row is gone is removed in the same pass (R1). While the row is listed the record stays, also with nothing left on disk: with a Notion-only protocol and the raw transcript off, the audio is the last local file, and removing the record with it would take the row's deletion line and its Move Meeting to Trash… (A12).
- **Triggers**: build it in `AppState` next to `remoteVocabulary` (`AppState.swift:191`) and start it from the launch `.task` (`MeetingTranscriberApp.swift:259-270`). After each meeting finishes (`.done`, which every naming path reaches): `onJobStateChange` is a single closure that `configureCallbacks` (`PipelineController.swift:381`) reinstalls on each queue rebuild, so chain the request in there, as the local-model notices chain theirs (`NotificationManager+LocalModel.swift:246-247`), and never assign the closure from outside.
- **Notion export ends**: a job stays `.done` through its export, so `onJobStateChange` does not fire when it ends. `exportToNotion` calls `onNotionExportFinished` at the end of every export, a first one, a retry or one a rebuilt queue restarted, with the status already final, and `configureCallbacks` installs that closure (`PipelineController.swift:404`): request a check there too, beside the notification (R12, A9). `PipelineQueue+Notion.swift` does not change.
- **Tests, written first** (`RecordingRetentionControllerTests`, temp folder, injected clock and calendar, a short interval): with Never nothing is deleted; with After 30 days a meeting recorded 31 days ago loses its audio for good while transcript and protocol stay, and one recorded 29 days ago keeps it until the clock passes the due date; Right after the notes deletes at once after done; imports, failed, kept, left-unfinished, protocol-failed and no-record meetings are never touched; a recovered recording from before this feature is never touched; a record changed between selection and deletion is skipped; a meeting pending in another live process is skipped; an unreachable folder deletes nothing and is retried at the next check; two overlapping `requestCheck` calls run one check; a finished job triggers a check; a meeting with a Notion export running keeps its audio, also with its Markdown on disk, and the export's end triggers the check that deletes it; a record whose files are all gone is pruned once its row is gone, and stays, with its deletion date, while the row is listed.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/RemoteVocabularyController.swift` - timer, clock injection, start guard, settings observation
- `app/MeetingTranscriber/Sources/PipelineController.swift:370-395` - `configureCallbacks`
- `app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift:235-255` - chaining `onJobStateChange`
- `app/MeetingTranscriber/Sources/AppState.swift:180-200` - where controllers are built

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/SingleFlight.swift` - one run at a time
- `app/MeetingTranscriber/Tests/RemoteVocabularyControllerTests.swift` - testing a timed controller

### Key context
- `AppSettings.effectiveOutputDir` silently falls back to `~/Downloads/MeetingTranscriber`; the check deletes only by the paths in the records and never resolves an output folder for that.
- `AppState.init` is constructed by unit tests: starting the timer belongs in the launch `.task`, not in `init`.
## Acceptance
- [ ] With a retention other than Never, the check deletes for good the audio of every recorded, finished, not kept meeting that is due, keeps its transcript, protocol and other files, and records the automatic deletion date (R11).
- [ ] Imports, failed meetings, meetings that left the queue unfinished, finished meetings whose protocol failed, kept meetings and meetings without a record are never touched; a meeting whose state changed after selection or with a Notion export running is skipped; an unreachable or undeletable file is logged, stays listed and is retried at the next check (R11).
- [ ] The check runs at launch, after each finished meeting (also when speakers are named later), when a Notion export ends, once a day and on `requestCheck`; it never runs twice at once and deletes nothing with Never (R12).
- [ ] A record none of whose files remains is removed once its row is gone; while the row is listed it stays, so the row keeps its deletion line and its Move Meeting to Trash… (R1, A12).
- [ ] `RecordingRetentionControllerTests` were written before the implementation, use an injected clock and calendar, and pass (R14).
## Done summary
With a retention other than Never, a finished recorded meeting that is due now loses its audio for good at launch, after it finishes, when its Notion export ends, once a day and on request, while its transcript, protocol and row stay and the record notes the automatic deletion date. The default Never deletes nothing, so this ships ahead of the Settings section (task .7).

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)
baseline: green via handoff (green (verified at 37c7e891 by the conductor; only .flow/ paths moved since))


### Gates (run on the committed code, no edits since)

- `gate classify`: FULL, exit 1, so the focused Quick classes ran.
- Spec's Quick filter: exit 0, 167 tests.
- `RecordingRetentionControllerTests` plus `PipelineControllerNotionRestoreTests`: exit 0, 69 tests (65 of them new).
- New classes with their neighbours (`RecordingRetentionRuleTests`, `RecordingAudioLineTests`, `MeetingFileRemoverTests`, `MeetingFileStoreTests`, `PipelineControllerTranscriptionsTests`, `PipelineControllerTests`, `PipelineControllerNotionExportTests`, `AppStateTests`, `NotificationManagerLocalModelTests`, `PipelineQueueMeetingFilesLifecycleTests`): exit 0, 340 tests.
- `./scripts/lint.sh`: exit 0, 0 violations in 1113 files.
- App Store variant, `swift build --build-tests -Xswiftc -DAPPSTORE` in a separate build folder: exit 0.


### Tests first

- Against compile-only stubs 47 of the first 63 tests failed on the stated values, for example "audio stayed" and a nil automatic date. The other 16 assert that audio stays, which a stub that does nothing also satisfies, so the guard run below is their evidence.
- Two tests came after the implementation, both from that guard run: `testACheckGoesByWhatTheRecordFileSaysNow` and `testAMarkThatFailsOnceStopsTheMeetingUntilTheNextCheck`.
- No existing test changed.


### Guards broken one at a time (a temporary runtime switch, one build, restored afterwards; not committed)

All 44 went red. The baseline with no guard broken stayed green. The first round left 2 survivors, a second `start()` and a refused pending mark, which the remover's own write check had hidden. I tightened `testStartRunsOneCheckAndASecondStartNoMore` and added the staging-folder test, and both then failed on their guard.

| Guard broken | Test that caught it |
| --- | --- |
| Record compare, read and lock together | `testARecordChangedAfterSelectionIsSkipped` |
| Lock compare alone | `testTheDeletionMarkIsRefusedForARecordThatChangedSinceItWasRead` |
| Queue state and setting asked again | `testAMeetingWhoseQueueStateChangedAfterSelectionIsSkipped`, `testASettingChangedAfterSelectionIsObeyed` |
| Notes gate, or notes out of reach counted as saved | `testNotesOutOfReachKeepTheAudioAndTheirMark`, `testNotesRemovedBehindTheAppKeepTheAudioAndGetMarked` |
| Pending mark leaving out unreachable files | `testPartlyReachableAudioGoesFileByFileAndIsDatedWhenTheLastOneGoes` |
| Date with nothing removed, a file refused, a file out of reach | `testAudioRemovedBehindTheAppIsMarkedGoneWithoutADate`, `testAFileThatCannotBeDeletedStaysListedAndIsRetried`, the partly reachable test |
| Trigger chained before the local-model notices | `testAJobEndingWithALocalModelNoticeStillSetsOffACheck` |
| Export task not counted as running | `testAReExportChainedBehindAnotherHoldsTheAudioThroughTheGapBetweenThem` |
| Unread snapshot not asked, or unreadable read as settled or as no row | `testAJobStillBusyInAnUnreadSnapshotKeepsItsAudio`, `testAnUnreadableSnapshotKeepsTheAudioAndTheRecord` |
| Request during a check lost, two checks at once | `testARequestDuringACheckRunsOneMoreAfterItAndNeverBesideIt`, `testTwoDirectChecksNeverRunBesideEachOther` |

The remaining guards were caught the same way: scope never opened, opened on the fallback or with nothing to do, each pruning condition, the timer, the first check at `start()`, the delay, the injected clock and calendar, starting in `init`, and the Trash in place of `.forGood`.

Removing only the read compare in `deleteAudio` is not caught by a flow test, because the lock compare behind it stops the same deletion. Each is tested through the other being off or directly.


### Not run

Full suite, sanitizers, `swiftlint analyze` (every new declaration has a reader, checked by search only), a run of the real app. Tests delete with the real `unlink` inside a temp folder. "Out of reach" is measured with a folder moved away and with permissions 000. No real network volume was tried.


### Similar code search

- Reused: `RecordingRetentionRule`, `MeetingFileRemover` in `.forGood`, `MeetingFilePresence`, `reconcileInterruptedDeletions` for a stopped deletion, `SecurityScopeAccess`.
- Extended: `MeetingFileStore.beginDeletion` with `unchangedFrom:`, which defaults to nil so the manual actions read as before, and a new `remove(unchanged:)`. `configureCallbacks` gained one call.
- Followed: `RemoteVocabularyController` for the `started` guard, the timer loop and nothing happening before `start()`.
- New: `RecordingRetentionController`, with its `PipelineController` answers in the same file because `PipelineController.swift` is 5 lines below `file_length`.


### Files

Split files of my own, inside Touches under the brief's rule: `Tests/RecordingRetentionControllerTests+Disk.swift`, `Tests/RecordingRetentionControllerTests+Triggers.swift`, `Tests/RetentionCheckBed.swift`. `AppState.swift` now sits at exactly 600 lines, the `file_length` limit, so the next added line there has to move something out.

Task .7 is the first production caller of `requestCheck(after:)` with a delay. `isChecking` has no reader outside the controller yet. No doc changed: the retention sentence in `docs/architecture-macos.md` and the README text are in task .8's Touches, and nothing changes for a user until task .7 offers a value other than Never.


### Decisions

DECIDED: notes the record marks present and the disk answers gone keep the audio and get marked gone, and notes out of reach keep the audio with the mark unchanged (rule 1: "a protocol counts as saved when its file is there", R11).
DECIDED: with notes off the transcript has to be on disk, and a meeting whose transcript is gone keeps its audio at every later check too (rule 1: A1). Only a saved protocol removes the raw transcript, so a finished meeting with notes off lists one unless someone removed it by hand.
DECIDED: a completed Notion export counts without asking the disk, also with the local file still there (rule 1: A8).
DECIDED: the setting is read once for the pass and asked again right before a meeting's files go, so Never or a longer period set during a check keeps the audio at once (rule 1: R12 "with the setting Never it deletes nothing"). The task text's "read once" holds for selection, and the second read can only keep audio.
DECIDED: audio that was all gone already gets its entries marked gone and no date, so the row reads "Audio not found" (rule 1: R11, the date says the app deleted it).
DECIDED: the pending mark lists every selected file, also those out of reach, and no mark is written when none is reachable (rule 1: a crash must not let `settleInterrupted` date a deletion that left a file behind).
DECIDED: a job only in the unread snapshot answers from that file, and an unreadable file answers unsettled and listed, which keeps the audio and the record (rule 1: the safety floor, and building the queue would resume saved jobs).
DECIDED: a chained re-export counts as running while its task exists, as the status reads completed between two exports (rule 1: A9).
DECIDED: a record goes only when the disk answers gone for every listed path, also those marked gone, as a file can come back from the Trash (rule 1: R1).
DECIDED: pruning also runs under Never, as it removes only a record with nothing left on disk and no row (rule 6).
DECIDED: an in-progress record is not pruned, as another build may be between moving a file and listing its new path (rule 6).
DECIDED: one waiter plus a check-again flag instead of `SingleFlight`, as a request during a run would otherwise be lost (rule 1: the task names both).
DECIDED: the earliest moment asked for wins in `requestCheck(after:)`, so a setting's delay never holds up a finished meeting (rule 6).
DECIDED: the clock of `RecordingRetentionController(pipeline:)` is `pipeline.now`, the one the manual deletions date by (rule 6).


### Known limits

- With notes off and the transcript removed by hand, the row's audio line and task .7's preview still say the audio will go, since `RecordingRetentionRule` does not look at the transcript, while the check keeps it. The check never deletes more than the rule promises, only less, in this one case.
- Audio that went partly in one pass and whose last file was then removed by hand reads "Audio not found" with no date, as the last pass deleted nothing.
- An export running in another build is not visible here. With Markdown on disk the meeting counts as saved anyway, as a failed export would, and without Markdown the rule keeps the audio.
- A file that keeps failing is logged at each check (one line, the meeting's short id and counts at public privacy, the system's text at private), and nothing tells the user beyond the row's line.


### Follow-ups

FOLLOW-UP: `TerminalJobStore` reads its file only at init, so a row another build added after launch is invisible to the pruning. The cost is the record of a meeting with nothing left on disk, and no file.
FOLLOW-UP: `MeetingFileRemover.remove` is `@MainActor` and asks `MeetingFilePresence` and unlinks there, so a volume that stalls after the off-main probe can block the main actor for that moment.
FOLLOW-UP: the async scope helper in the controller repeats `withOutputFolderScope`, which is private in `PipelineController+Transcriptions.swift`, outside this task's Touches.
FOLLOW-UP: to let the row and the preview match the check for notes off without a transcript, `RecordingRetentionRule.audioToDelete` could require a present transcript entry. `RecordingRetention.swift` is outside this task's Touches.

stage: impl-review - ran (model: gpt-6-astra xhigh (codex:gpt-6-astra:xhigh)); verdict SHIP after 2 round(s)
DECIDED: panel of three in round 1, as the prompt and the skill's panel rule ask for a change that deletes for good and touches shared state. All three draws said NEEDS_WORK and reproduced their findings with temporary-folder probes. Merged to five; the validator kept all five. Round 2 (one reviewer, resumed) said SHIP (rule 1: the skill's panel rule).
DECIDED: all five findings fixed, none declined. The receipt marks #1, #2, #3 (P1) and #4, #5 (P2) `fixed`, and the re-review found nothing new (rule 1: R1, R11, R12, the prompt's "any way this check can delete a file the spec says stays").
DECIDED: #1, the notes gate asks for a regular file the app can read, through a link too. A folder, a dangling link, a link to a folder or a file without read permission keeps the audio and leaves the record as it is (rule 1: R11, the prompt's bar). A link to a real file counts as saved, with a test.
DECIDED: an empty regular notes file still counts as saved, as a silent meeting with notes off may have an empty transcript and would keep its audio for good (rule 1: R11 "a protocol counts as saved when its file is there").
DECIDED: #2, a failed snapshot read is noted on the queue and handed to a queue that adopts its jobs. Until the next launch a meeting the queue does not hold answers unsettled and listed, so nothing of it is deleted or pruned (rule 1: the task's earlier decision for an unreadable file, and the safety floor).
DECIDED: #3, Keep is decided under the store's lock and refused while a deletion is pending, so the first of the two wins. An automatic deletion also asks the record under the lock before each file, for writes that take no notice of the mark, and answers `meetingChanged`. Manual deletions are not held back (rule 1: R8, R11). A refused Keep changes nothing on the row, as `setKeep` refusals already do.
DECIDED: `RecordingRetentionRule.recordAllowsDeletion` holds what the record alone must say, used by `audioToDelete` and by the store, so the two cannot drift (rule 6).
DECIDED: #4, when no selected file answers present, what is gone is marked and no deletion begins, so a crash has no mark to date. A mix of present and gone files still goes through the mark (rule 1: the task's decision that audio already gone gets no date).
DECIDED: #5, every rebuild requests a check, not only one whose restore finished a job. The cost is one read of the record file, and it does nothing under Never. A rebuild before `start()` can therefore run a check, as a job's callback already could; `init` still does nothing (rule 6).
DECIDED: the fix touches files outside the task's Touches: `Sources/MeetingFilePresence.swift`, `Sources/MeetingFileRemover.swift`, `Sources/PipelineController+Transcriptions.swift`, `Sources/PipelineQueue.swift`, `Sources/PipelineQueue+Recovery.swift` (`loadSnapshot` sits at `function_body_length`, so its failure path moved to a small helper), `Sources/RecordingRetention.swift`, `Tests/MeetingFileRemoverTests.swift`, and the new split file `Tests/RecordingRetentionControllerTests+HeldBack.swift` (rule 6). No existing assertion was weakened; one row was added to the remover's reason table.
DECIDED: evidence, tests first. Against compile-only stubs 9 new tests failed on the stated values, for example 6 files removed where 1 should go, 7 writes holding a mark where none should, and all audio gone behind a folder at the notes path. Three that guard against refusing too much passed, as they should.
DECIDED: evidence, guards broken one at a time and restored: 15 went red on the named tests. One survived at first (a queue with an engine reading the file again), so its test now waits for the snapshot write and corrupts the file afterwards, and it then went red. One first attempt failed to build and was redone. Not caught by any test: `PipelineController.setKeep` calling the store's `setKeep` rather than `update`, as nothing can step in between its read and its write.
DECIDED: evidence, final tree, committed with no edits after these. The focused and neighbouring classes in one test process (`CFFIXED_USER_HOME=<scratch> swift test --filter <26 class names>`): exit 0, 499 tests. `./scripts/lint.sh` with the pinned tools: exit 0, 0 violations in 1114 files. Not run: App Store build, `swiftlint analyze`, full suite, sanitizers (the step runs them), a run of the real app.
DECIDED: one earlier `--parallel` run of the same 499 tests on the same code exited 1 on a single test, `MeetingFileStoreTests.testAWriteFailsWhenTheLockStaysHeldPastTheBound` (985 s against its 5 s limit), while the machine stalled, with the run taking hours at a load average up to 47. It is a wall-clock assertion on lock code the fix does not change. It passed in the one-process run straight after and in an earlier `--parallel` run of the fix (measured, cause inferred).
DECIDED: reviewers wrote nothing that stays: `git status` after each round showed only flowctl's bookkeeping. They reported two bookmark or scope tests failing inside their own sandbox; `testADeletionRunsInsideTheScopeOfTheChosenFolderAndClosesIt` passes here, and the 499-test run exited 0. My test runs used the scratch home and temp folders only, and reviewers were told the same and reported fresh temporary homes. Nothing ran against a real recordings folder or the installed app in my runs.
DECIDED: lesson captured as an uncommitted `.flow/memory/bug/data/` entry for the step to commit. `.flow/specs/gh-97-delete-recordings-by-hand-and-after-a.json` holds flowctl's review bookkeeping, also uncommitted (rule 1: the review brief).
FOLLOW-UP: `RecordingAudioLine` and task .7's preview (spec gh-97) still say the audio will go when a folder, a link or an unreadable file stands at the notes path, while the check keeps it. The check never deletes more than they promise. Matters when someone asks why audio outlived its date.
FOLLOW-UP: `PipelineQueue.noteOutcome` and other pipeline writes (spec gh-97) take no notice of a pending automatic mark, so such a write from another build costs the file already started before the next file stops. Matters if a meeting can be re-run in one build within the moment another build deletes its audio.
FOLLOW-UP: `RecordingRetentionController.jobsTheQueueHasNotRead` (spec gh-97): after a failed snapshot read automatic deletion holds until the next launch and only the log says so; a later save replaces the file, so the next launch no longer knows of a job that was in it. Matters if an unreadable snapshot recurs, or held a busy job whose record already said finished.
FOLLOW-UP: `PipelineController.setKeep` (spec gh-97) has no test proving it uses the store's locked `setKeep`. Matters if that line is refactored back to `update`; the lock test on the store would still pass.
FOLLOW-UP: `MeetingFileStoreTests.testAWriteFailsWhenTheLockStaysHeldPastTheBound` (spec gh-97) asserts wall-clock time and fails when the machine stalls. Matters on a heavily loaded runner, where it reads as a regression in the store.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 3b4591ea8350f5d5284d0aa862e7870e66c6d827, d56e5323bf04d47e4ed9afa20061a6ffbedd990e
- Tests: CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'RecordingRetentionControllerTests|PipelineControllerNotionRestoreTests' (exit 0, 69 tests), CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'RecordingRetentionControllerTests|RecordingRetentionRuleTests|RecordingAudioLineTests|MeetingFileRemoverTests|MeetingFileStoreTests|MeetingFileRecordTests|PipelineControllerTranscriptionsTests|PipelineControllerTests|PipelineControllerNotionExportTests|AppStateTests|NotificationManagerLocalModelTests|PipelineQueueMeetingFilesLifecycleTests' (exit 0, 340 tests), CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'TranscriptionsViewTests|TranscriptionListTests|RecordingRowActionsTests|RowAvailabilityTests|PipelineControllerTranscriptionsTests|TranscriptionsWindowPrivacyTests|TerminalJobStoreTests|TerminalJobRecordTests|AudioPersistencePolicyTests|OutputSettingsViewTests|SpeakerNamingStoreTests|ProcessedRecordingsLedgerTests' (exit 0, 167 tests), ./scripts/lint.sh (exit 0, 0 violations), swift build --build-tests -Xswiftc -DAPPSTORE in a separate build folder (exit 0)
- PRs: