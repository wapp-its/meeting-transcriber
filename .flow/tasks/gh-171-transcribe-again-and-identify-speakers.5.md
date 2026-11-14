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
- The action goes through `AllRecordingsActions` (built in `MeetingTranscriberApp.swift:180-226`) to `PipelineController` and `rerunJob`; a refusal for gone or unreachable audio keeps the sheet open with A18's line, and one for files of the last re-run still left with A27's line; queued closes it.
- `A11yID`: `recordingMenuTranscribeAgain(index)` beside the other menu ids (`A11yID.swift:160-185`) and ids for the sheet's buttons.

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
- [ ] Row decision tests: the item follows Regenerate Notes with D5's separators; absent without a record, for a failed meeting, a meeting waiting for names and when none of its source audio was found; disabled while the meeting waits, runs or has a Notion export running, with a deletion pending or incomplete, while a regeneration runs, with its audio only on a drive that is not connected, and in record-only mode.
- [ ] The "…" menu and the right-click menu list the same items.
- [ ] Sheet text tests: D6's drawn case word for word, each case of A16, A18's two lines, A27's line.
- [ ] ViewInspector tests located by `A11yID`: the item opens the sheet for its row; Cancel closes it and queues nothing; the default button calls the action; a refusal keeps the sheet open with its line.
- [ ] The row menu snapshot test, if it covers this menu, is updated deliberately.
- [ ] The Quick commands' focused tests and `./scripts/lint.sh` pass.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
