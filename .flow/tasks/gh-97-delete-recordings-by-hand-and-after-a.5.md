---
satisfies: [R2, R4, R5, R6, R8, R14]
---
# gh-97-delete-recordings-by-hand-and-after-a.5 All Recordings rows: audio line, Keep, the two Trash actions and Retry Deletion

## Description
Puts the manual slice in front of the user: each row in All Recordings shows its audio line and Keep badge, its "…" menu and right-click menu gain Keep and the two Trash items, each Trash item asks first with task .4's text, and an incomplete deletion shows "Retry Deletion" as the row's main button. The view renders task .4's decisions and calls task .3's actions; it decides nothing itself. With this task the first usable slice (record plus manual deletion plus Keep) is complete.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/TranscriptionsView.swift`, `app/MeetingTranscriber/Sources/AllRecordingsActions.swift`, `app/MeetingTranscriber/Sources/RowAvailability.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift`, `app/MeetingTranscriber/Tests/RowAvailabilityTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/TranscriptionsView.swift, app/MeetingTranscriber/Sources/AllRecordingsActions.swift, app/MeetingTranscriber/Sources/RowAvailability.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift, app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift, app/MeetingTranscriber/Tests/RowAvailabilityTests.swift]

### Approach
- **Inputs**: extend `AllRecordingsActions` (`AllRecordingsActions.swift:7-60`, and `.noop` at `:51`) with `meetingFiles: (UUID) -> MeetingFileRecord?`, `audioOnDisk: (TranscriptionEntry) -> RecordingAudioLine.AudioOnDisk?`, `moveAudioToTrash`, `moveMeetingToTrash`, `retryDeletion`, `setKeep`, and `retention: () -> RecordingRetention`. Wire them in `MeetingTranscriberApp.allRecordingsActions` (`MeetingTranscriberApp.swift:199-224`) to the controller actions of task .3 and to `settings.recordingRetention`. The live facts for task .4's decisions come from the row's `TranscriptionEntry`: `state` and `liveNotionExport == .inProgress` while `isLive`, nil for an entry known only from the history.
- **Disk reads stay cached**: `RowAvailability` (`RowAvailability.swift`) already caches each row's `FilesOnDisk` and is refreshed on appear and after each action (`TranscriptionsView.swift:76-79`, `:264`, `:279`). Cache the audio presence and size there too, using task .1's `MeetingFilePresence`, and keep present, unreachable and gone apart: an unreachable file adds no bytes but is never treated as gone, so a disconnected drive shows the not-connected line and keeps Keep and Move Audio to Trash… (R2). Never read the disk per redraw. The cache must also follow the record store: task .6 deletes audio while the window may be open, and `TranscriptionEntry` carries no audio state, so invalidate a row's cached audio facts whenever its `MeetingFileRecord` changes (the store is `@Observable`; compare per job, e.g. by a change counter or the record's value).
- **Row** (`TranscriptionsView.swift:163-194`): the audio line goes in the row's `VStack` after `outcome`; the Keep badge after the title; the incomplete reason replaces the status line while a deletion is incomplete, as the mockup's "Design review" row shows. The main button handles `.retryDeletion`.
- **Menu** (`rowMenu`, `:247`, shared by the "…" button and `.contextMenu`): render the new `MenuItem` cases with `title(of:)` (`:300`) and `identifier(of:)` (`:312`); Keep shows a check mark when kept. The gh-170 test `testTheMoreMenuListsExactlyTheRowsMenuItems` must be updated to the new list, not weakened. The More button stays.
- **Confirmations**: hold the pending confirmation (which action, which meeting, its text) in one `@Observable` object the view owns, like `TranscriptionsFileNotice` (`TranscriptionsView.swift:11`) and `ProtocolTemplatesModel.pendingDeletion` (`Settings/ProtocolTemplatesSettingsView.swift:178`), so a test can assert where a tap landed (CLAUDE.md, GUI testing, layer 2). Present it as an `.alert` with "Cancel" and the destructive "Move to Trash"; the file names go in the message. Cancel clears it; confirm calls the action, refreshes `RowAvailability`, and clears it.
- **Identifiers**: new `A11yID` functions for the three menu items, the Retry Deletion button and the Keep badge, row-indexed like the existing ones (`A11yID.swift:113-146`). Add nothing to the `/ui/*` allowlists; `TranscriptionsWindowPrivacyTests` must stay green.
- **Tests**: `TranscriptionsViewTests` (one wiring test per control, located by `A11yID`, with the recording actions of `makeView`/`recording(into:)`): the audio line text for a recorded row; tapping Move Audio to Trash… sets the pending confirmation and calls nothing; confirming calls `moveAudioToTrash` with the row's id; Move Meeting to Trash… likewise; Keep calls `setKeep` with the toggled value; Retry Deletion as the main button calls `retryDeletion`; a row without a record shows no audio line and none of the three items. `RowAvailabilityTests`: audio size and presence are cached and recomputed on refresh; an unreachable folder is reported as unreachable, not gone; a change to a meeting's record (audio deleted by the store while the window stays open) updates that row's cached size and menu availability without a refresh.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/TranscriptionsView.swift` - rows, menu, notices, refresh points
- `app/MeetingTranscriber/Sources/AllRecordingsActions.swift` - the actions value and `.noop`
- `app/MeetingTranscriber/Sources/RowAvailability.swift` - the per-row cache
- `app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift` - `makeView`, `recording(into:)`, `button(_:in:)`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:195-230`, `:370-395` - action wiring and the window scene
- `app/MeetingTranscriber/Sources/Settings/ProtocolTemplatesSettingsView.swift:170-200` - a Trash confirmation in this app

### Key context
- A `@State` mutation from a ViewInspector tap lands in a copy and is not assertable; that is why the pending confirmation lives in an `@Observable` object.
- The window shows meeting titles; it must stay off `/ui/tree`, `/ui/press`, `/ui/type` and `/screenshot` (`TranscriptionsWindowPrivacyTests.swift`).
## Acceptance
- [ ] Each row with a record shows its audio line, and a kept meeting its Keep badge, from task .4's decision and cached disk sizes; a row without a record shows neither; a disconnected drive shows the not-connected line and keeps the Keep and Trash items; a record changed while the window is open (automatic deletion) updates the row without reopening the window (R2, R4, A2).
- [ ] The "…" menu and the right-click menu list Keep (Never Delete Automatically) with its check mark, Move Audio to Trash… and Move Meeting to Trash… after Regenerate Notes…, present and enabled as task .4 decides; the gh-170 menu test is updated to the new list (R4).
- [ ] Each Trash item asks first with task .4's text; Cancel changes nothing; confirming runs the action and the row then shows the new audio line, disappears (Move Meeting) or shows "Deletion incomplete" with a Retry Deletion main button (R5, R6, D7).
- [ ] Keep toggles the meeting's Keep mark (R8).
- [ ] Every new control has one ViewInspector wiring test located by an `A11yID` constant; All Recordings stays off every `/ui` and screenshot allowlist (R14).
- [ ] The spec's quick command passes.
## Done summary
Each row with a record in All Recordings now shows its audio line and Keep badge, its "…" and right-click menus list Keep (with a check mark) and the two Trash items after Regenerate Notes…, each Trash item asks first with task .4's text, and a stopped deletion shows its reason with Retry Deletion as the main button. A record changed while the window is open updates the row: `RowAvailability` caches the disk read per record value, so a changed record reads its audio once and an idle redraw reads nothing.

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)
baseline: green via handoff (green (verified at c6045f1a by the conductor; only .flow/ paths moved since))


### Gates (run on the committed code, no edits since)

- `gate classify`: FULL, exit 1, so the focused Quick classes ran.
- Quick classes plus `TrashConfirmationTextTests` and `RecordingAudioLineTests`: exit 0, 200 tests, of which 164 belong to the spec's Quick filter. `TranscriptionsWindowPrivacyTests` is green and no allowlist changed.
- `./scripts/lint.sh`: exit 0, 0 violations in 1107 files.
- App Store variant, `swift build --build-tests -Xswiftc -DAPPSTORE` in a separate build folder: exit 0.

### Tests first

- `RowAvailabilityTests`: the 4 new tests failed on compile-only stubs with the stated values, then 7 passed.
- `TranscriptionsViewTests`: 14 of 27 failed against the unchanged view (the 13 new tests and the rewritten gh-170 test), then 27 passed.
- Updated existing test: `testTheMoreMenuListsExactlyTheRowsMenuItems` (gh-170). The spec changes the menu, so it now compares against the new list. It keeps its 5 original rows, adds 8 rows with records, and compares ids and disabled flags for every item, toggles included.

### Measured in a hosted window (throwaway test, not committed; temp folder, no real Trash, not the installed app)

- Menu items in order: Open Notes, Open Transcript, Show in Finder, Regenerate Notes…, Keep (Never Delete Automatically) with its state on, Move Audio to Trash…, Move Meeting to Trash…, the last one disabled while a regeneration runs.
- The alert attaches as a sheet with task .4's text. Cancel holds Escape, Move to Trash holds no Return shortcut, and clicking Move to Trash ran the action and closed the sheet.
- A record changed with the window open caused 1 record read and 1 audio read, then 0 audio reads while idle.

### Not run

Full suite, sanitizers, `swiftlint analyze` (every new declaration has a reader, checked by search only), a GUI drive through the running app (the window is off every `/ui` allowlist; the wiring tests and the hosted measurement cover it).

### Similar code search

- Reused: `MeetingFilePresence`, `RowAvailability`, the security-scope pattern of `readFilesOnDisk`, the `TranscriptionsFileNotice` observable-object pattern, the `syntheticTag` badge style.
- New: `AllRecordingsActions.readAudioOnDisk`, `TrashConfirmationPrompt`.

### Files

- Split files of my own, inside Touches: `Sources/TranscriptionsView+RowLabels.swift` (the view passed the 400-line type limit, so the labels and identifiers moved) and `Tests/TranscriptionsViewTests+MeetingFiles.swift`.
- `PipelineController+Transcriptions.swift` needed no change.
- `.flow/features` does not exist, so no route change to name. The docs belong to task .8.

### Decisions

ASSUMED: `AudioOnDisk.totalCount` leaves out a 16 kHz copy the record lists as gone, as the pipeline removes those itself once speakers are named and "5 of 6 files moved" would misstate a meeting with three tracks · alternatives: B — count every listed audio file also those gone, as the dispatch note and the field's comment say · flip at: AllRecordingsActions.readAudioOnDisk · test: testTheCountsFollowTheRecordAndTheDisk
ASSUMED: while a Regenerate Notes runs, Move Meeting to Trash… and the Retry Deletion of a Move Meeting are disabled on every row, as the regenerator runs one meeting at a time and does not say which · alternatives: B — per meeting, which needs the regenerator to publish its job (ProtocolRegeneration.swift, outside Touches); C — no rule, with a stray notes file possible · flip at: TranscriptionsView.isRegenerating and its readers isEnabled and mainButton · test: testWhileARegenerationRunsNothingRemovesAWholeMeeting
ASSUMED: while a deletion is incomplete, its reason takes the status line's place in orange with a warning symbol · alternatives: B — a separate line under the status · flip at: TranscriptionsView.statusLine · test: testRetryDeletionIsTheMainButtonWhileADeletionIsIncomplete
ASSUMED: the Keep badge is a small outlined "Keep" beside the title, in the `syntheticTag` style · alternatives: B — a line of its own under the title · flip at: TranscriptionsView.keepBadge · test: testARowShowsItsAudioLineAndBadgeFromItsRecord
DECIDED: the regeneration rule lives in the view, as `RecordingRowActions.swift` is outside Touches and the phase is already passed to the view (rule 6)
DECIDED: Keep is a `Toggle`, which a menu draws with a check mark (rule 6)
DECIDED: the alert's buttons carry `A11yID` constants, as every new control needs one (rule 1: the task's acceptance on A11yID wiring tests)
DECIDED: the new action fields return nothing, and a refused action leaves the row as it was (rule 1: the spec's "stays as it was")
DECIDED: the view passes `Date()`, the current calendar and the current locale to `RecordingAudioLine.resolve` (rule 6)

### Follow-ups

FOLLOW-UP: a row's first audio read runs on the main actor during a draw, as `FilesOnDisk` does, while the comments on `MeetingFilePresence` and `AudioOnDisk` say never from a view body. A hung network mount would hold the window until the read returns.
FOLLOW-UP: the controller's actions call `FileManager.trashItem` on the main actor, reported as the dispatch asked and left as it is.
FOLLOW-UP: a regeneration started from a notification's Try Again while the Move Meeting dialog is open is not caught, as `confirm` does not check the phase again. A stray notes file stays possible in that case.
FOLLOW-UP: a confirmed action that the controller refuses (a pending mark that fails to save, a state that changed behind the dialog) shows no message; the row only stays as it was.
FOLLOW-UP: the comment on `AudioOnDisk.totalCount` in `RecordingAudioLine.swift`, outside Touches, still says every listed audio file. It needs the clause from the first ASSUMED line, or the assumption flips.

stage: impl-review - ran (model: gpt-6-astra xhigh (codex:gpt-6-astra:xhigh)); verdict SHIP after 2 round(s)
DECIDED: panel of three in round 1, as the diff is about 1,200 lines, wires the destructive actions and adds a cache that follows the shared record store. All three reviewers found the same two defects and each reproduced them with fixtures and the fake Trash; the validator kept both (rule 1: the skill's panel rule).
DECIDED: both findings fixed, none declined. The receipt marks #1 (P1) and #2 (P2) `fixed`, and the re-review found nothing new (rule 1: R5, R6).
ASSUMED: when a file would move that the dialog did not name, nothing moves, the row stays as it was, the window shows "Nothing was moved: the meeting's files changed while the dialog was open. Choose the action again to see what it moves now.", and choosing the item again names the file · alternatives: B — show an updated dialog at once, which a request set inside the alert's own button may lose, since SwiftUI can clear the binding before or after the button runs · flip at: TranscriptionsView.confirm · test: testAFileThatCameBackAfterTheDialogOpenedIsNotMovedUnnamed
DECIDED: fewer files than the dialog named goes ahead, as moving less than asked harms nothing; the stated sizes can then read high for that one action (rule 6; test: testConfirmingStillRunsWhenAFileWentSinceTheDialogOpened).
DECIDED: the message stays until a Trash item is chosen again, as the window's "The file was moved or deleted." also outlasts other actions (rule 6).
DECIDED: `TranscriptionEntry.hasNotionPage` answers from the page id in the job and in the history record, also the record's url. `notionPageURL` keeps its meaning, so Open in Notion and the row's menu still follow the completed export only (rule 1: R6 "for a meeting with a Notion page"; the field's comment "so nothing opens a partial page").
DECIDED: the fix touches files outside the task's Touches: `Sources/TranscriptionList.swift` (the new entry field), `Sources/TrashConfirmationText.swift` (one shared `files(of:record:audio:)`, used by both dialogs and the check), `Tests/TranscriptionListTests.swift`, and the split test file `Tests/TranscriptionsViewTests+MeetingDeletion.swift` (the file passed the 600-line limit, so the tests over the real controller moved there; their shared helpers `texts`, `trashAlert` and `tapInTrashAlert` lost `private`) (rule 6).
DECIDED: tests changed in this task's own file. `testConfirmingReadsTheRowsFilesAgain` now counts the confirmation's own audio read, [2, 3] instead of [2, 2]. `testTheConfirmationIsBuiltFromWhatTheRowFound` expected the missing line for a failed export with a page, which was the defect: it now expects the line, with a new row for a failed export that never made a page. New: `testAFileThatCameBackAfterTheDialogOpenedIsNotMovedUnnamed` (both Trash items, real files, fake Trash), `testConfirmingStillRunsWhenAFileWentSinceTheDialogOpened`, `testAnEntryKnowsOfANotionPageAFailedExportLeftBehind` (rule 1: the brief's rule on a test whose behaviour is deliberately changed).
DECIDED: evidence. Tests first: against a compile-only stub the new tests exited 1 with 9 failures, each on the stated value, including 3 files moved where none should and the missing Notion line; the one guarding against over-refusal passed, as it should. After the fix those 5 tests exited 0. The spec's focused classes exited 0 with 203 tests, and `lint.sh` with the pinned tools exited 0 with 0 violations, both on the tree that was committed. The reviewers reported two security-scope tests failing inside their own sandbox; those classes pass here. Not run: App Store build, `swiftlint analyze`, full suite, sanitizers (the step runs them).
DECIDED: reviewers wrote nothing that stays: `git status` after each round showed only flowctl's bookkeeping, and their temporary probes were gone. No reviewer or fix used the real Trash on real data or ran the installed app.
DECIDED: lesson captured as an uncommitted `.flow/memory/bug/ui/` entry, for the step to commit. `.flow/specs/gh-97-delete-recordings-by-hand-and-after-a.json` holds flowctl's review bookkeeping, also uncommitted (rule 1: the review brief).
FOLLOW-UP: task .8 (spec gh-97): the one confirmation for several meetings needs the same check as `TranscriptionsView.confirm`, using `TrashConfirmationText.files(of:record:audio:)`, or a file back on disk goes to the Trash without having been named or counted. Matters as soon as multi-select is built.
FOLLOW-UP: `TranscriptionsView.namesEveryFileToMove` (spec gh-97) reads the record from the store without the reload the controller's action does. Matters only if the other build adds a file to the same record while the dialog is open; the action would then move a file the check did not see.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 624af4a0e642e1760e17aaac46fd9ffd52ee74f5, 900ea83f7729f62ace9b17e4c08f0bdcd12985c7, f03aa0d487e3d941bd64f3ca68a467d89c8b046b
- Tests: CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'TranscriptionsViewTests|TranscriptionListTests|RecordingRowActionsTests|RowAvailabilityTests|PipelineControllerTranscriptionsTests|TranscriptionsWindowPrivacyTests|TerminalJobStoreTests|TerminalJobRecordTests|AudioPersistencePolicyTests|OutputSettingsViewTests|SpeakerNamingStoreTests|ProcessedRecordingsLedgerTests|TrashConfirmationTextTests|RecordingAudioLineTests', ./scripts/lint.sh, swift build --build-tests -Xswiftc -DAPPSTORE
- PRs: