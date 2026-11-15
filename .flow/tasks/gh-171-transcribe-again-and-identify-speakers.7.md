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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
