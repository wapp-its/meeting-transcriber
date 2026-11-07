---
satisfies: [R9, R10, R12, R14]
---
# gh-97-delete-recordings-by-hand-and-after-a.7 Settings → Output: the Recordings section and the preview

## Description
The Settings side: a "Recordings" section in Settings → Output with the picker "Delete recordings automatically" and its three help lines (R9), and the preview that stops a value from taking effect until the user has seen what it deletes (R10). The preview counts from task .4's rule and its confirm button asks task .6's controller for a check.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/RetentionPreview.swift` (new), `app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift`, `app/MeetingTranscriber/Sources/SettingsView.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Sources/RecordingRetentionController.swift`, `app/MeetingTranscriber/Tests/RetentionPreviewTests.swift` (new), `app/MeetingTranscriber/Tests/OutputSettingsViewTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/RetentionPreview.swift, app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift, app/MeetingTranscriber/Sources/SettingsView.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Sources/RecordingRetentionController.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Tests/RetentionPreviewTests.swift, app/MeetingTranscriber/Tests/OutputSettingsViewTests.swift]

### Approach
- **Preview, pure** (`RetentionPreview`): from the records, the live-state lookup, a candidate retention, `now` and a size lookup `(MeetingFile) -> Int64?`, return the meetings whose audio task .4's rule would delete now, their count and total size, and the counts skipped. The mockup's text: title "Delete the audio of 14 meetings?"; "With “After 30 days”, 14 meetings recorded more than 30 days ago still have their audio (5.2 GB). It is deleted for good within the next minute. Transcripts and meeting notes stay."; "Meetings marked Keep, failed meetings and imported files are skipped. Recordings made before this feature existed are not touched."; buttons "Delete Audio of 14 Meetings" (destructive, red text) and "Cancel" (the default). Word the Right after the notes case to match ("… 14 finished meetings still have their audio …"); singular for one meeting.
- **Controller side**: `RecordingRetentionController` exposes `preview(for: RecordingRetention) -> RetentionPreview` (it already holds the store, live states, clock and the size lookup through `MeetingFilePresence`) and the confirm path `apply(_ retention:)`, which writes the setting and calls `requestCheck(after:)` with a few seconds.
- **Section** in `OutputSettingsView` (`Settings/OutputSettingsView.swift:31`), directly under "Output Folder", above `NotionExportSettingsView` and the section "Meeting Notes": the picker with R9's five titles and the three help lines quoted in R9. The view takes only `settings` today; give it a preview provider and the apply closure the way `SpeakersSettingsView` receives its dependencies (`SettingsView.swift:95-103`, the call site at `:107`), wired in `MeetingTranscriberApp`.
- **Confirm before apply**: the picker's binding is a custom `Binding(get:set:)` (pattern at `Settings/TranscriptionSettingsView.swift:~280-292`) whose setter first compares the candidate with the stored value: Never or a longer time than the stored one applies at once without a preview, even when overdue audio is still waiting for the next check (R10). Order the values by how soon they delete (Right after the notes, 7, 30, 90 days, Never) in one place on `RecordingRetention`. Only a shorter value asks the preview: no meeting affected → apply at once; otherwise park the pending value and the preview in an `@Observable` model the view owns, and show an `.alert` with Cancel as the default button and the destructive confirm button. Cancel drops the pending value, so the picker shows the stored one again. Test the longer-value case with an overdue meeting present: it must apply without asking.
- **Record-only**: the section stays enabled in record-only mode (spec edge case); do not apply `recordOnlyDisabled` to it.
- **Identifiers**: `A11yID.recordingRetentionPicker` and the two alert buttons where ViewInspector can reach them.
- **Tests, written first**: `RetentionPreviewTests` for each value, Keep, imports, failed meetings, a running Notion export, Right after the notes, singular and plural, and an empty result; `OutputSettingsViewTests` (the `find(viewWithAccessibilityIdentifier:)` then `find(ViewType.Picker.self)` then `select(value:)` locator, `SettingsInteractionTests.swift:166-183`): selecting a value that affects nothing writes the setting; selecting a longer value while an overdue meeting is present writes it without asking; selecting one that affects meetings parks it in the model and leaves the setting unchanged; confirming writes it and calls apply; cancelling leaves it.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift:31-110` - the sections
- `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift:270-300` - an intercepted picker with an alert
- `app/MeetingTranscriber/Sources/SettingsView.swift:90-115` - how settings tabs get dependencies
- `app/MeetingTranscriber/Tests/SettingsInteractionTests.swift:160-185` - picker locator by identifier

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/OutputSettingsViewTests.swift` - the tab's existing tests
- `app/MeetingTranscriber/Tests/ViewInspectorIdentifierTests.swift` - why the two-step locator works

### Key context
- macOS alerts do not make `.cancel` the default button by themselves; check which button Return activates and give Cancel `.keyboardShortcut(.defaultAction)` if needed, since the mockup makes Cancel the default for a permanent delete.
- The setting stays one value so #11 (an organisation lock) can lock it later; do not split it per output folder or profile.
## Acceptance
- [ ] Settings → Output shows "Recordings" directly under "Output Folder", above the Notion export and "Meeting Notes" sections, with the picker "Delete recordings automatically" (five values, default Never) and R9's three help lines; it stays enabled in record-only mode (R9).
- [ ] A value under which at least one meeting's audio would be deleted at once shows the preview with the count, the total size, "deleted for good within the next minute", that transcripts and meeting notes stay and what is skipped, with Cancel as the default and a destructive confirm button (R10).
- [ ] Confirming saves the value and starts a check within a minute; Cancel keeps the previous value; a value that affects no meeting, Never and a longer time than the stored one are saved without asking, also while overdue audio waits for the next check (R10, R12).
- [ ] The picker and the alert buttons have ViewInspector wiring tests located by `A11yID` constants; `RetentionPreviewTests` cover every value and skip reason and were written first (R14).
## Done summary
Settings > Output now has a Recordings section with the picker "Delete recordings automatically", and a value that would delete audio at once first shows what goes, with Cancel as the default button, while the setting keeps its old value. Confirming saves the value and starts a check 5 seconds later. Never, a longer time and a value affecting no meeting are saved without asking and start no check.

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)
baseline: green via handoff (green (verified at 094643db by the conductor; only .flow/ paths moved since))


### Gates (run on the committed code, no edits since)

- `gate classify`: FULL, exit 1, so the focused Quick classes ran.
- Spec's Quick filter: exit 0, 186 tests.
- `RetentionPreviewTests` plus `OutputSettingsViewTests`: exit 0, 52 tests (40 of them new).
- New classes with their neighbours (`RecordingRetentionRuleTests`, `RecordingRetentionControllerTests`, `SettingsViewTests`, `SettingsInteractionTests`, `RecordingAudioLineTests`, `NotificationManagerLocalModelTests`): exit 0, 301 tests.
- `./scripts/lint.sh`: exit 0, 0 violations in 1116 files.
- App Store variant, `swift build --build-tests -Xswiftc -DAPPSTORE` in a separate build folder: exit 0.
- `swiftlint analyze --strict` after a clean `xcodebuild build-for-testing`: exit 2, 1 violation in 1019 files, none of them this task's. `private struct Refused: Error {}` at `Tests/PipelineControllerTranscriptionsTests+MeetingDeletionFlows.swift:11` has no reader. An earlier task of this spec added that file and it is outside this task's Touches, so it stays. CI's analyze job fails on it until the line goes.


### Tests first

- The tests ran first against compile-only stubs: 28 of 50 failed on the stated values, for example the alert's texts and a 5 s wait with nothing read. 12 of the 22 that passed were existing tests. The other 10 are new and a do-nothing stub satisfies them, so the guard run below is their evidence.
- The first run against the implementation failed 2 new tests on my own expectations, and I corrected both. `testCancelIsTheDefaultButton` collected the same Return key twice from the view's mirror, and now compares sets. `testEachValueCountsAMeetingFromItsDueDateOn` expected "Right after the notes" to count a meeting a second before its recording date, while `RecordingRetentionRule.dueDate` answers the recording date.
- Two tests came after the implementation, from the guard run and from reading the wiring: `testAKeepWrittenThroughAnotherStoreCounts` and `testTheSettingsWindowGivesTheTabItsActions`.
- No existing test changed.


### Guards broken one at a time (source edit, one build, restored afterwards; not committed)

All 39 went red, and the tree was clean after each batch. The first round left 1 survivor, `store.reload()` in `preview(for:)`, which then failed on its new test.

| Guard broken | Test that caught it |
| --- | --- |
| Stored value counted as sooner, 7 and 30 days swapped | `testChoosingTheStoredValueAgainAsksNothing`, `testValuesAreOrderedByHowSoonTheyDelete` |
| Meeting with all audio gone counted, shared path counted twice | `testAudioRemovedByHandIsNotCountedAndNotMarked`, `testAPathTwoMeetingsListIsCountedOnce` |
| Each skip reason, skip without audio, a waiting meeting counted as kept | `testEverySkipReasonLeavesTheMeetingOutAndIsCounted`, `testAMeetingWithoutAudioLeftIsNoSkip`, `testAMeetingThatHasToWaitIsNeitherCountedNorSkipped` |
| Queue asked about every meeting | `testTheQueueIsAskedOnlyAboutAMeetingTheRecordWouldLetGo` |
| Stale answer taken, value affecting nothing not saved, longer value asks | `testAnAnswerForAValueTheUserLeftIsDropped`, `testAValueThatAffectsNothingIsSavedWithoutAsking`, 11 tests |
| Confirm applying nothing, or reading the cleared state | `testConfirmingAppliesTheValueAndClosesTheAlert`, `testConfirmingStillAppliesWhenTheBindingWasClearedFirst` |
| Apply saving nothing, starting no check, checking at once, delay of 61 s | `testApplySavesAtOnceAndHoldsTheCheckBackForItsDelay`, `testThePreviewCountsWhatTheCheckThenDeletes` |
| Scope never opened, never closed, opened with nothing to read | `testTheChosenFoldersScopeIsOpenWhileTheDiskIsReadAndClosedAfter`, `testNothingToReadOpensNoScopeAndReadsNothing` |
| Disk read on the main actor | `testTheDiskIsReadOffTheMainActorAndTheWindowGoesOn` |
| Section below Notion, disabled in record-only, dropped by the settings window | `testTheSectionSitsDirectlyUnderOutputFolderAboveNotionAndMeetingNotes`, `testTheSectionStaysEnabledInRecordOnlyMode`, `testTheSettingsWindowGivesTheTabItsActions` |
| Cancel not the default, confirm not destructive, each `A11yID` removed | `testCancelIsTheDefaultButton`, `testTheAlertSaysWhatThePreviewSaysWithCancelAndARedConfirmButton`, the wiring tests |
| Closing the alert keeping the value, no waiting line, picker on the stored value, two values offered | `testClosingTheAlertAnotherWayIsACancel`, `testAChoiceWaitingForTheDiskSaysSoAndSavesNothing`, `testThePickerOffersTheFiveValuesAndStartsAtNever` |


### Measured in a real window (temporary, not committed)

- A test hosted the real tab with a real `RecordingRetentionController` and test files in a temp folder. The section appeared directly under Output Folder. Choosing After 30 days raised a sheet with the expected title and text, `defaultButtonCell` was Cancel and the confirm button had `hasDestructiveAction`. Return closed it with the setting at Never and all 6 audio files on disk. Clicking the confirm button saved After 30 days and deleted the 6 files.
- Key events on a SwiftUI alert, macOS 26. Without `.keyboardShortcut(.defaultAction)` Return does nothing and Escape cancels. With it Return cancels and Escape does nothing.


### Not run

Full suite, sanitizers, a run of the real app. The closures in `MeetingTranscriberApp` are checked by the compiler only. Test files live in the system temp folder through `makeTempDirectory`, the helper the earlier tasks of this spec use, and no test reaches a real recordings folder or the installed app. No real network volume was tried: `testAFolderOutOfReachIsNotNoAudio` measures "out of reach" with the audio folder moved away, and the slow volume is a blocked injected read in `testTheDiskIsReadOffTheMainActorAndTheWindowGoesOn`.


### Similar code search

- Reused: `RecordingRetentionRule.audioToDelete` for the selection, `MeetingFilePresence` for the disk's answer, `openOutputFolderScope`, `requestCheck(after:)`.
- Followed: the `presenting` alert of `TranscriptionsView`, `.alert` on a single row as in `TranscriptionSettingsView`, `legacyWhisperModels` for an optional forwarded state.
- Extended: `RecordingRetentionController` with `preview(for:)` and `apply(_:)`.
- New: `RetentionPreview`, `RetentionChoice`, `RetentionSettingsActions`, `RecordingsSettingsSection`.


### Files

`Sources/RetentionPreview.swift` (new), `Sources/RecordingRetentionController.swift`, `Sources/Settings/OutputSettingsView.swift`, `Sources/SettingsView.swift`, `Sources/MeetingTranscriberApp.swift`, `Sources/A11yID.swift`, `Tests/RetentionPreviewTests.swift` (new), `Tests/OutputSettingsViewTests.swift`. `MeetingTranscriberApp.swift` now has 599 lines, one below `file_length`. `AppState.swift` and `PipelineController.swift` did not change. `SettingsView.detailView(for:)` lost `private` for its test.

Task .8 has `docs/architecture-macos.md` and the README in its Touches, so no doc changed here. This task adds the settings section, the alert and the 5 s check after a confirmed value for it to describe.


### Decisions

DECIDED: Cancel carries `.keyboardShortcut(.defaultAction)`, which costs Escape on this alert as measured above (rule 1: R10 "Cancel as the default button"). Removing that one line in `RecordingsSettingsSection.previewButtons` gives the behaviour of the trash alert, and `testCancelIsTheDefaultButton` pins it.
DECIDED: `preview(for:)` is `async` instead of the task's synchronous signature, and it reads the disk off the main actor (rule 1: the conductor's note on a slow or missing volume).
DECIDED: the disk answers present with a size, gone or unreachable, and a meeting with audio out of reach counts (rule 1: the conductor's note, "a folder out of reach is not 'no audio'"). A meeting whose audio the disk confirms is all gone is left out, as the check skips it.
DECIDED: the mockup's skip sentence stays word for word, and the skip counts go to a `notice` log line (rule 1: the task's quoted text).
DECIDED: a value saved without asking starts no check, and only a confirmed one does (rule 1: R12 "after a confirmed setting change", R10).
DECIDED: a shorter value affecting no meeting is saved without a check too, as nothing would go (rule 6).
DECIDED: the delay after confirming is 5 seconds (rule 1: the task's "a few seconds", R10 "within a minute").
DECIDED: the order of values lives in an extension on `RecordingRetention` inside `RetentionPreview.swift`, as `RecordingRetention.swift` is outside this task's Touches (rule 1: Touches).
DECIDED: `OutputSettingsView` without its actions leaves the section out, so no path saves a value unseen (rule 6, as `legacyWhisperModels` does).
DECIDED: a choice still waiting for the disk is dropped when the tab is left, and nothing is saved (rule 6).
ASSUMED: wording for audio out of reach, "(at least 30 MB) ... and what is on a drive that is not connected once that drive is back" when partly out of reach and ", on a drive that is not connected. It is deleted for good once that drive is back." when wholly · alternatives: B — count such audio without saying so; C — leave such meetings out of the alert · flip at: `RetentionPreview.sizeAndWhen` · test: `testTheTextSaysWhatIsOutOfReach`
ASSUMED: while the disk answers, the picker shows the chosen value and a caption reads "Checking which meetings this would delete…" · alternatives: B — no line, picker stays on the stored value · flip at: `RecordingsSettingsSection.body` · test: `testAChoiceWaitingForTheDiskSaysSoAndSavesNothing`


### Known limits

- Escape does nothing on this alert, measured above. Return and the Cancel button close it.
- The preview promises what `RecordingRetentionRule` says. The check keeps more in the cases the rule cannot see, as the conductor's note accepts: notes off with the transcript removed by hand, and a folder, a link or an unreadable file at the notes path. It never deletes more.
- The confirmed value's check deletes what the rule selects at that moment, so a meeting that became due between the alert and the check goes too (R10).
- `openOutputFolderScope` resolves the folder's bookmark on the main actor, as the tab's `body` already does on every render through `outputDirDisplay`.


### Follow-ups

FOLLOW-UP: a volume that never answers leaves the choice waiting without a time bound. Nothing is saved or deleted, the caption stays, and another pick takes over.
FOLLOW-UP: the unused `Refused` struct in `Tests/PipelineControllerTranscriptionsTests+MeetingDeletionFlows.swift:11` needs its one line removed before a CI request.

stage: impl-review - ran (model: gpt-6-astra xhigh (codex:gpt-6-astra:xhigh)); verdict SHIP after 2 round(s)
DECIDED: panel of three in round 1, as the prompt asks. All three draws said NEEDS_WORK and reproduced their findings with temporary-folder probes. Merged to three P1 findings (integration draw's #1 and #3, correctness draw's #2); the validator kept all three. Round 2 (one reviewer, resumed) said SHIP (rule 1: the prompt and the skill's panel rule).
DECIDED: all three findings fixed, none declined. The receipt marks #1, #2 and #3 (P1) `fixed`, and the re-review found nothing new (rule 1: R10, the prompt's bar for a path that saves a value unconfirmed).
DECIDED: #1, `MeetingFileStore.reload()` now answers false on a failed read, and `preview(for:)` answers nil instead of going by the store's older records (rule 1: R10). The return is `@discardableResult`, so other callers are unchanged.
DECIDED: #2, `liveMeetingState` stays as it is, as its waiting answer is right for the check and an earlier task's test pins it. `PipelineController.knowsLiveState` tells that answer from a job known to be waiting, and `RetentionPreview.Selection.isComplete` carries it. The queue is asked only about a meeting the record would let go (rule 1: R10, the task's earlier decision to ask the queue only about such a meeting).
DECIDED: one meeting whose job cannot be known makes the whole answer nil, also when other meetings could be counted, as a partial count promises less than goes once the queue answers (rule 1: the prompt's bar). After a snapshot read the queue noted as failed, this holds until the next launch, and it can only keep audio.
DECIDED: #3, `preview(for:)` asks the rule again after each disk read until it selects nothing unread, so the answer comes from a selection made after the last suspension. Each file is read once per preview, inside one scope, and the loop ends as every pass but the last adds at least one path (rule 1: R10; R10's "what the rule selects at that moment" covers only the time after a confirmation).
DECIDED: `preview(for:)` returns an optional rather than a flag on the preview, so the caller has to decide (rule 6).
DECIDED: the fix touches files outside the task's Touches: `Sources/MeetingFileStore.swift` (the return value) and the new `Tests/RetentionPreviewFreshAnswerTests.swift`, a new class as `OutputSettingsViewTests` sits at `type_body_length` (rule 6). In `Tests/RetentionPreviewTests.swift` seven call sites follow the optional return through a small helper that unwraps it; no assertion changed or weakened.
DECIDED: evidence, tests first. Against the new interface with the old behaviour 12 of 16 new tests failed on the stated values, for example a preview of 0 meetings where nil was due, 0 where a meeting had finished during the read, and one run where the setting went to After 30 days unasked and the check then deleted the audio. The 4 that passed guard against refusing too much or pin the single scope, and the guard run below is their evidence.
DECIDED: evidence, guards broken one at a time and restored, 14 of 14 went red on the named tests, with 4 run again after one test moved to the new class. Not run as a guard: removing `.subtracting(answers.keys)`, which would loop for ever instead of failing an assertion.
DECIDED: evidence, final tree, committed with no edits after these. The focused and neighbouring classes in one test process (`CFFIXED_USER_HOME=<scratch> swift test --filter <20 class names>`): exit 0, 486 tests. `./scripts/lint.sh` with the pinned tools: exit 0, 0 violations in 1117 files. App Store variant, `swift build --build-tests -Xswiftc -DAPPSTORE` in a separate build folder: exit 0. Not run: `swiftlint analyze`, full suite, sanitizers (the step runs them), a run of the real app. The closures in `MeetingTranscriberApp` and the wiring in `RecordingRetentionController.init(pipeline:)` are the same as before except for the optional; `testASnapshotThatDoesNotReadTellsNothing` runs the latter on a real `PipelineController`.
DECIDED: reviewers wrote nothing that stays: `git status` after each round showed only flowctl's bookkeeping. In round 2 the reviewer's run of 68 tests had 2 failures inside its sandbox, both the bookmark setup it was told to ignore (`XCTUnwrap` of `customOutputDir`); the same 68 pass here. My test runs used the scratch home and temp folders only, and reviewers were told the same and reported fresh temporary homes. Nothing ran against a real recordings folder or the installed app in my runs.
DECIDED: lesson captured as an uncommitted `.flow/memory/bug/data/` entry for the step to commit. flowctl reported high overlap with this spec's earlier entry on deletion signals and I kept both: that one is about what a guard proves, this one about a skipped confirmation reading "could not tell" as zero. `.flow/specs/gh-97-delete-recordings-by-hand-and-after-a.json` holds flowctl's review bookkeeping, also uncommitted (rule 1: the review brief).
ASSUMED: a value whose effect cannot be told is not saved, the picker goes back, and a caption under it reads "Could not read which meetings “After 30 days” would delete, so the setting did not change. Try again later." until the next choice · alternatives: B — an alert with the same text and an OK button; C — no line, the picker just goes back · flip at: `RecordingsSettingsSection.body` (`choice.notChecked`) · test: `testAValueWhoseEffectCannotBeToldIsNotSavedAndSaysSo`
FOLLOW-UP: `RecordingsSettingsSection` caption (spec gh-97): after a snapshot read the queue noted as failed, "Try again later" keeps failing until the next launch, and the line does not say so. Matters if an unreadable snapshot recurs and someone cannot turn the setting on.
FOLLOW-UP: `RecordingRetentionController.currentSelection` (spec gh-97): `liveMeetingState` and `knowsLiveState` read the same snapshot file one after the other on the main actor, so a file that starts reading between the two could still read as a known waiting job. Matters only if a snapshot's permissions change in that moment; it would then read as nothing to delete.
FOLLOW-UP: `RetentionChoice.choose` (spec gh-97): one reviewer's probe in round 1 saw a pending empty answer save the value after a hosted Settings window closed, while leaving the tab drops it; it was no finding, as a value affecting nothing is saved without asking by R10, and I did not repeat the probe. Matters if closing the window should drop the choice too.
FOLLOW-UP: `docs/architecture-macos.md` and the README (spec gh-97, task .8): the description of the Recordings section should also say that a value is not saved when what it deletes cannot be told.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: af33e808613de06be76c4c92fa35c745657e2f06, 7773357f355f53d52a173d54ec28e20ce0a6cc86
- Tests: CFFIXED_USER_HOME=<scratch> swift test --filter 'RetentionPreviewTests|OutputSettingsViewTests' (exit 0, 52 tests), CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'RetentionPreviewTests|OutputSettingsViewTests|RecordingRetentionRuleTests|RecordingRetentionControllerTests|SettingsViewTests|SettingsInteractionTests|RecordingAudioLineTests|NotificationManagerLocalModelTests' (exit 0, 301 tests), CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'TranscriptionsViewTests|TranscriptionListTests|RecordingRowActionsTests|RowAvailabilityTests|PipelineControllerTranscriptionsTests|TranscriptionsWindowPrivacyTests|TerminalJobStoreTests|TerminalJobRecordTests|AudioPersistencePolicyTests|OutputSettingsViewTests|SpeakerNamingStoreTests|ProcessedRecordingsLedgerTests' (exit 0, 186 tests), ./scripts/lint.sh (exit 0, 0 violations), swift build --build-tests -Xswiftc -DAPPSTORE in a separate build folder (exit 0), swiftlint analyze --strict --compiler-log-path <clean xcodebuild log> (exit 2, 1 violation, in a test file this task did not touch)
- PRs: