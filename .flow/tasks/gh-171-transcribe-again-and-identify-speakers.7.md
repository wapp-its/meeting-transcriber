---
satisfies: [R8, R9, R11]
---
# gh-171-transcribe-again-and-identify-speakers.7 Offer Identify Speakers Again in the row, with its sheet

## Description
Slice 2's user-facing half (R8, R9, D7, A16, A17, A21): the second row item and the Identify Speakers Again sheet, on task 5's row decision and sheet plumbing and task 6's mode.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/RecordingRowActions.swift`, `app/MeetingTranscriber/Sources/TranscriptionsView.swift`, `app/MeetingTranscriber/Sources/TranscriptionsView+RowLabels.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Sources/AllRecordingsActions.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/RerunSheetText.swift`, a new `app/MeetingTranscriber/Sources/IdentifySpeakersAgainSheet.swift`, tests
**Touches:** [app/MeetingTranscriber/Sources/RecordingRowActions.swift, app/MeetingTranscriber/Sources/TranscriptionsView*.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Sources/AllRecordingsActions.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/RerunSheetText.swift, app/MeetingTranscriber/Sources/IdentifySpeakersAgainSheet.swift, app/MeetingTranscriber/Sources/PipelineController*.swift, app/MeetingTranscriber/Tests/RecordingRowActionsTests.swift, app/MeetingTranscriber/Tests/TranscriptionsViewTests*.swift, app/MeetingTranscriber/Tests/RerunSheetTextTests.swift, app/MeetingTranscriber/Tests/IdentifySpeakersAgainSheetTests.swift]

### Approach
- The item comes directly after Transcribe Again and before D5's closing separator, absent and disabled by the same rules (R8).
- Sheet: the method as a radio group in `DiarizerMode.displayOrder` with `displayName` and `methodDescription`, as Settings draws it (`Settings/SpeakersSettingsView.swift:183-197`); "Expected speakers" with a number in the naming dialog's range (`SpeakerNamingView.rerunCountRange`), shown while Standard is picked; starting values from `settings.diarizerMode` and `settings.numSpeakers` (0, Auto, starts at 2). A17: the naming dialog's `rerunMethodHint` in the count's place for Sortformer and Nemotron 3, and `micSideNote` under the count for a recorded call.
- Texts from `RerunSheetText`: D7's lines, A21's case without kept timings (the orange line in place of "The text stays."), A16's notes-off case. The sheet knows timings are kept when the record lists a present `segments` file.
- The default button passes the chosen method and count to `rerunJob`'s Identify Speakers Again mode; refusals as in task 5.
- `A11yID`: `recordingMenuIdentifySpeakersAgain(index)` and ids for the method group, the count and the buttons.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/Settings/SpeakersSettingsView.swift:40-70,180-215`
- `app/MeetingTranscriber/Sources/SpeakerNamingView.swift:140-190`
- `app/MeetingTranscriber/Sources/AppSettings.swift:60-110`
**Optional:**
- `app/MeetingTranscriber/Tests/SpeakerNamingRerunLayoutTests.swift`
- `app/MeetingTranscriber/Tests/SpeakerNamingViewTests.swift`

### Design context
No `DESIGN.md`. The look is the accepted board written out in Architecture (D7): the method list in a white box headed "Speaker method", the count indented under it, the line for a meeting without kept timings in orange.

## Acceptance
- [ ] Row decision tests for R8: the item follows Transcribe Again in both menus and is absent and disabled by R2's rules.
- [ ] Sheet text tests: D7's drawn case word for word, A21's case without kept timings, the notes-off case, and A17's hint and note per method and track layout.
- [ ] ViewInspector tests located by `A11yID`: picking Sortformer or Nemotron 3 hides the count and shows the hint, Standard shows the count; the sheet starts at the Settings' method and count (2 for Auto); the default button passes the chosen method and count; Cancel queues nothing.
- [ ] The Quick commands' focused tests and `./scripts/lint.sh` pass.
- [ ] Both build variants build in release (`./scripts/pre-push.sh --with-appstore`), and the fork's CI run (both variants' tests) is requested on the final head before the merge (R11).
## Done summary
A finished meeting's row in All Recordings now lists "Identify Speakers Again…" right after "Transcribe Again…" in both menus, between D5's separators. It is listed, left out and greyed out by the same rule as Transcribe Again (R8). It opens D7's sheet: the method radio list, the count, A17's hint and note, and A21's orange line. The default button "Identify Speakers" hands the picked method and count to `PipelineController.rerunJob(id:mode: .identifySpeakersAgain, speakers:)`, which now has a `speakers:` parameter (R9).

stage: impl-review - ran (codex:gpt-6.1-sol:xhigh, three lenses, SHIP, no findings; the receipt names gpt-6.1-sol at xhigh)

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

Baseline: green. Before any edit, the build passed and 260 focused tests passed (the Quick filter plus RerunSheetTextTests and TranscribeAgainSheetTests).

### Verification on the committed head (6ec8f0b0)
- `swift build -j 6 --build-tests`: exit 0. No new warnings in the changed files.
- Focused tests: the Quick filter plus RerunSheetTextTests, TranscribeAgainSheetTests and IdentifySpeakersAgainSheetTests, run with `--num-workers 2`. Exit 0, 271 tests; all 11 new tests ran.
- `./scripts/lint.sh` with the pinned SwiftFormat 0.64.6 and SwiftLint 0.65.1: 0 violations. `TranscriptionsView.swift` is at 597 lines, under the 600-line limit.
- Release builds, the variant steps of `pre-push.sh --with-appstore`, run with `-j 6`:
  - `swift build -c release`: exit 0.
  - `swift build -c release -Xswiftc -DAPPSTORE --scratch-path .build-appstore`: exit 0.
  - Both printed one warning in `Settings/Notification+SettingsWindow.swift`, a file this task did not touch.
  - The script's local-model-helper step was not run: this change does not touch the helper.
- Wiring check: each of these five changes made a named test fail for the stated reason, and every line was restored afterwards:
  - the view's enabled switch treating the item as always enabled;
  - the confirm passing a fixed count;
  - the word timings flag set to a constant;
  - the Settings read replaced by the defaults;
  - the sheet modifier removed.

### Tests per acceptance criterion
- **Row decision (R8):** `RecordingRowActionsTests`
  - `testTheReRunItemsFollowRegenerateBetweenSeparators` checks the order and separators, also with reports and while the meeting runs.
  - `testTheReRunItemsAreAbsentWhereNoReRunCanStart` and `testTheReRunItemsAreDisabledWhileAReRunWouldBeRefused` check both items against every case of R2.
- **Both menus:** `TranscriptionsViewTests.testBothMenusListTheReRunItemsAsTheRowDecides` checks that Identify Speakers Again comes right after Transcribe Again. `testTheItemFollowsRecordOnlyModeAndARunningRegeneration` covers both items.
- **Sheet texts:** `RerunSheetTextTests`
  - `testTheIdentifySheetsDrawnCaseWordForWord`: D7, including the method names and descriptions.
  - `testTheIdentifySheetWithoutWordTimingsAndWithoutNotes`: A21, A16, and both together.
  - `testWhatStandsUnderTheMethodListPerMethodAndTrackLayout`: A17, with the hint and note given as literal strings, for 3 methods × 2 track layouts.
  - `testTheCountStartsAtSettingsExpectedSpeakers`: Auto starts at 2.
  - `testTheMeetingIsWhatTheRowShowed`: the word timings flag comes from the record's segments entry.
- **ViewInspector by `A11yID`:** `IdentifySpeakersAgainSheetTests`
  - `testPickingAMethodShowsTheCountOrTheMethodsHint`
  - `testTheSheetStartsAtSettingsMethodAndCount`
  - `testTheDefaultButtonPassesTheChosenMethodAndCount`: picker and stepper driven, then the button.
  - `testCancelClosesTheSheetAndQueuesNothing`
  - `testARefusalKeepsTheSheetOpenWithItsLine`
  - `testTheSheetShowsItsTexts`
- **Window:** `TranscriptionsViewTests.testIdentifySpeakersAgainOpensItsSheetForItsRowAndQueuesTheSpeakersPicked`.

Tests changed by declared intent (R8 adds an item where the old tests expected none):
- The three Transcribe Again row-decision tests are renamed. They now expect both items, which makes them stronger.
- `TranscriptionsViewTests+MeetingFiles.isDisabled` gains the new case.

Snapshot updated deliberately: `testSnapshotOfTheRowMenuWithLongReportNames` was re-recorded in record mode. The new image shows "Identify Speakers Again…" after "Transcribe Again…" and before the separator above Keep. It was checked by eye against D5 and passed against itself in the focused run.

### Decisions and assumptions (reversible)
1. **Word timings:** the sheet treats them as kept when the record lists a segments file that is not gone (`MeetingFileRecord.keptWordTimings`), as the task spec says. The run also checks the file on disk. A segments file removed or replaced by hand would therefore show "The text stays." while the run transcribes again.
2. **Count control:** it follows Settings' pattern, the number next to a Stepper, over the naming dialog's range of 1 to 10. For Sortformer and Nemotron 3 the count is still passed to the queue, where the method ignores it, as the naming dialog's Re-run does.
3. **Refusal texts:** they are Transcribe Again's. `alreadyRerunning` reads "The meeting is already being transcribed again." in this sheet too.
4. **Sheet file:** the sheet is presented by a `View` extension in its own file, because `TranscriptionsView.swift` is at the file-length limit.
5. **Method picker label:** "Speaker method" is hidden visually and kept for accessibility; the grey heading shows it.

### Not covered by a test
- The pass-through of `speakers:` in `PipelineController.rerunJob` and the `identifySpeakersAgain` closure in `MeetingTranscriberApp`: both were checked by compiling only, because `PipelineControllerTests` is outside this task's Touches.
- The orange colour of the A21 line: it is visual.

### Follow-ups
- `docs/automation-api.md` names only Transcribe Again as making a finished job live again; Identify Speakers Again does too. The docs are outside this task's Touches.
- R11's fork CI run on the final head belongs to the merge step.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 6ec8f0b0ef8ac44185c116e16016c7bfb181311f
- Tests: cd app/MeetingTranscriber && swift build -j 6 --build-tests (exit 0), CFFIXED_USER_HOME=<scratch> swift test --skip-build --parallel --num-workers 2 --filter <Quick filter>|RerunSheetTextTests|TranscribeAgainSheetTests|IdentifySpeakersAgainSheetTests (exit 0, 271 tests), ./scripts/lint.sh with pinned SwiftFormat 0.64.6 and SwiftLint 0.65.1 (0 violations), swift build -c release -j 6 (exit 0), swift build -c release -j 6 -Xswiftc -DAPPSTORE --scratch-path .build-appstore (exit 0)
- PRs: