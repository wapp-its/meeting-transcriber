---
satisfies: [R2, R3, R11]
---
# gh-171-transcribe-again-and-identify-speakers.5 Offer Transcribe Again in a finished meeting's row, with its sheet

## Description
The user-facing half of slice 1 (R2, R3, D5, D6, A16, A18, A19): the row item in both menus with D5's separators, the pure row decision's new inputs, the Transcribe Again sheet with its pure texts, and the wiring to `rerunJob`. Built after task 4, so slice 1's pipeline is complete when its row item appears.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/RecordingRowActions.swift`, `app/MeetingTranscriber/Sources/TranscriptionsView.swift`, `app/MeetingTranscriber/Sources/TranscriptionsView+RowLabels.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Sources/AllRecordingsActions.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, new `app/MeetingTranscriber/Sources/RerunSheetText.swift` and `app/MeetingTranscriber/Sources/TranscribeAgainSheet.swift`, tests
**Touches:** [app/MeetingTranscriber/Sources/RecordingRowActions.swift, app/MeetingTranscriber/Sources/TranscriptionsView*.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Sources/AllRecordingsActions.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/RowAvailability.swift, app/MeetingTranscriber/Sources/RerunSheetText.swift, app/MeetingTranscriber/Sources/TranscribeAgainSheet.swift, app/MeetingTranscriber/Sources/PipelineController*.swift, app/MeetingTranscriber/Tests/RecordingRowActionsTests.swift, app/MeetingTranscriber/Tests/TranscriptionsViewTests*.swift, app/MeetingTranscriber/Tests/RerunSheetTextTests.swift, app/MeetingTranscriber/Tests/TranscribeAgainSheetTests.swift]

### Approach
- A new `RowMenuItem` case for the item, placed by `menuItems(...meeting:)` (`RecordingRowActions.swift:198-225`) after Regenerate Notes and before Keep and the Trash items, with D5's separators; today no separator precedes Regenerate when the meeting has no reports (`reportGroup`, 181-185). The other items keep today's order (A19).
- New inputs to the pure decision: record-only mode (`AppSettings.recordOnly`), whether any regeneration runs (`isRegenerating`, `TranscriptionsView.swift:382`), and the source audio's last look: present, only unreachable, or none. `readAudioOnDisk` (`AllRecordingsActions.swift:184-204`) reads owned audio only, so an import's own file is missing from it: add a source-track read through `MeetingFilePresence.of`, cached in `RowAvailability` like today's read.
- Sheet: a second sheet beside the regenerate sheet's single `.sheet(isPresented:)` (`TranscriptionsView.swift:98`), better as `.sheet(item:)`; layout like `RegenerateProtocolView` (94-145; Cancel with `.cancelAction`, the action with `.defaultAction`). All texts come from pure `RerunSheetText` functions: D6's wording word for word, A16's cases, A18's lines.
- Values as Settings labels them: engine `TranscriptionEngineSetting.label`, the model's picker label (`TranscriptionSettingsView.whisperKitModels`, custom models, Parakeet), the language's picker label (`PickerLanguages`), vocabulary `customVocabularyEnabled`, speakers `diarize` and `diarizerMode.displayName`, " · 2 tracks" when the record lists both tracks.
- The action goes through `AllRecordingsActions` (built in `MeetingTranscriberApp.swift:188-233`) to `PipelineController` and `rerunJob`; a refusal for gone or unreachable audio keeps the sheet open with A18's line, and one for files of the last re-run still left with A27's line; queued closes it.
- `A11yID`: `recordingMenuTranscribeAgain(index)` beside the other menu ids (`A11yID.swift:137-200`) and ids for the sheet's buttons.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/RecordingRowActions.swift:150-235`
- `app/MeetingTranscriber/Sources/TranscriptionsView.swift:90-160,237-425`
- `app/MeetingTranscriber/Sources/AllRecordingsActions.swift:1-120,184-204`
- `app/MeetingTranscriber/Sources/RegenerateProtocolView.swift:94-145,260-290`
**Optional:**
- `app/MeetingTranscriber/Tests/RecordingRowActionsTests.swift:294-345` (state matrix)
- `app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift:23-63,168-195,284-325`

### Design context
No `DESIGN.md`. The look is the accepted board written out in Architecture (D6): the system sheet style of the regenerate sheet, grey secondary text, one white box for the four settings rows.

### Key context
- `TranscriptionsView.swift` is at 571 lines (SwiftLint warns at 600): the sheet and its texts go in their own files.
- SwiftUI builds both menus on every redraw: the decision reads only cached availability, never the disk (gh-170).
## Acceptance
- [ ] Row decision tests: the item follows Regenerate Notes with D5's separators; absent without a record, for a failed meeting, a meeting waiting for names and when none of its source audio was found (a notes-only meeting from Generate Meeting Notes from Transcript, whose record lists no source audio, among them); offered for a finished meeting held for Retry Meeting Notes; disabled while the meeting waits, runs or has a Notion export running, with a deletion pending or incomplete, while a regeneration runs, with its audio only on a drive that is not connected, and in record-only mode.
- [ ] The "…" menu and the right-click menu list the same items.
- [ ] Sheet text tests: D6's drawn case word for word, each case of A16, A18's two lines, A27's line.
- [ ] ViewInspector tests located by `A11yID`: the item opens the sheet for its row; Cancel closes it and queues nothing; the default button calls the action; a refusal keeps the sheet open with its line.
- [ ] The row menu snapshot test, if it covers this menu, is updated deliberately.
- [ ] The Quick commands' focused tests and `./scripts/lint.sh` pass.
## Done summary
A finished meeting's row in All Recordings now lists "Transcribe Again…" in both menus after "Regenerate Notes…", between D5's separators, greyed out where a re-run would be refused. It opens a sheet with D6's wording and A16's cases. "Transcribe Again" calls `PipelineController.rerunJob(id:mode: .transcribeAgain)`: a queued re-run closes the sheet, and a refusal keeps it open with a red line (A18, A27).

stage: impl-review - ran (codex:gpt-6.1-sol:xhigh, three lenses, SHIP, no findings)

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

Baseline: green (build, and 239 focused tests from the Quick filter, before any edit).

Verification on the committed tree:
- `swift build -j 6 --build-tests`: exit 0, no warnings in the changed files.
- Focused tests: the Quick filter plus RerunSheetTextTests, TranscribeAgainSheetTests, TranscriptionsSelectionTests and RecordingRowReportsTests, `--num-workers 2`. Exit 0, 275 tests, all 20 new tests among them.
- `./scripts/lint.sh` with the pinned SwiftFormat and SwiftLint: 0 violations.
- Wiring check: with the record-only and regeneration inputs dropped from the view, and the cached source-audio read replaced by a constant, `testTheItemFollowsRecordOnlyModeAndARunningRegeneration` and `testTheSourceAudioIsReadOncePerRefresh` fail for the stated reason. The lines were restored afterwards.

Tests per acceptance criterion:
- Row decision: `RecordingRowActionsTests` `testTranscribeAgainFollowsRegenerateBetweenSeparators`, `testTranscribeAgainIsAbsentWhereNoReRunCanStart`, `testTranscribeAgainIsDisabledWhileItsReRunWouldBeRefused` and `testTheSourceAudioIsThereWhileAnyTrackIs`.
- Both menus: `testBothMenusListTranscribeAgainAsTheRowDecides`.
- Sheet texts: `RerunSheetTextTests`, which covers D6 word for word, A16's cases, A18's two lines, A27's line, the Settings labels and the meeting line.
- ViewInspector by `A11yID`: `TranscribeAgainSheetTests` covers Cancel, the default button and a refusal. `testTranscribeAgainOpensTheSheetForItsRowAndQueuesItsMeeting` covers the item opening the sheet for its row.
- Source-audio read: `testTheSourceAudioIsReadWhereTheRecordListsIt` uses real temp files and covers an import's own file, a file on a drive that is not connected, and records that list no audio or list it as gone.

Snapshot updated deliberately: the row-menu snapshot test now gives its row source audio, so its menu shows "Transcribe Again…" after "Regenerate Notes…", between the reports' closing separator and a new separator above Keep. The image was re-recorded, checked by eye against D5, and then passed against itself.

Assumptions (reversible; each has a test):
1. The separators come only with the item. A row without it keeps today's menu (A19).
2. `RecordingRowActions.Meeting.sourceAudio` defaults to `.gone`. `menuItems` takes `recordOnly` and `isRegenerating` with false defaults, so the selection's Trash plan, which never reads them, is unchanged. The window passes all three, and a wiring test covers that.
3. Meeting line: the date and time and the length use the row's own formats (length as `48:00`, not the board's "48 min"). A missing date or length is left out.
4. Model value: a stock model shows the model picker's label; a model from another repository or a folder shows its variant name. Parakeet shows the engine label alone, because that label names its one model.
5. A language code the picker does not list is shown as stored. Auto-detect shows the picker's "Auto-detect".
6. The Notion line also needs notes on. Without a provider no notes are made and nothing is exported (`generateProtocol`: "No protocol, so no export"). The export counts as on when `notionExportEnabled` is set.
7. Refusals without spec wording: notFinished "The meeting is not finished."; deletionPending "A move of the meeting's files to the Trash is under way or did not finish."; alreadyRerunning "The meeting is already being transcribed again."; meetingBusy "The meeting is being processed or exported."; audioHeldElsewhere "The meeting's audio is in use by another job."; recordNotSaved "The meeting's list of files could not be saved."; rerunFileUnreadable "The app's saved jobs could not be read, so a re-run could not be resumed after a quit."
8. The sheet reads Settings on every redraw, so it shows what a click would take now.
9. `rerunJob` starts the pipeline first (`ensureQueue`), so a finished job known only from the unread snapshot is taken over, not run beside.

Not covered by a test: the closures in `MeetingTranscriberApp.allRecordingsActions`, which is private composition like its neighbours, and the two-line `PipelineController.rerunJob` wrapper, whose tests file is outside this task's Touches. Both were checked by compiling only. The App Store variant was not built locally. Nothing in the change is variant-gated, and CI builds both variants.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: f72d9abbd8b4855c5efbc1599b6e4e55ac159027
- Tests: cd app/MeetingTranscriber && swift build -j 6 --build-tests (exit 0), CFFIXED_USER_HOME=<scratch> swift test --skip-build --parallel --num-workers 2 --filter "RecordingRowActionsTests|RowAvailabilityTests|MeetingFileStoreTests|PipelineQueueRetryTests|PipelineQueueMeetingFiles|TerminalJobStoreTests|SpeakerNamingStoreTests|LateRerunCancelTests|TranscriptionsViewTests|RegenerateProtocolViewTests|MeetingNotesRetryTests|LocalModelGateWiringTests|RerunSheetTextTests|TranscribeAgainSheetTests|TranscriptionsSelectionTests|RecordingRowReportsTests" (exit 0, 275 tests), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 (exit 0, 0 violations)
- PRs: