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
- **Preview, pure** (`RetentionPreview`): from the records, the live-state lookup, a candidate retention, `now` and a size lookup `(MeetingFile) -> Int64?`, return the meetings whose audio task .4's rule would delete now, their count and total size, and the counts skipped. The mockup's text: title "Delete the audio of 14 meetings?"; "With “After 30 days”, 14 meetings recorded more than 30 days ago still have their audio (5.2 GB). It is deleted for good within the next minute. Transcripts and protocols stay."; "Meetings marked Keep, failed meetings and imported files are skipped. Recordings made before this feature existed are not touched."; buttons "Delete Audio of 14 Meetings" (destructive, red text) and "Cancel" (the default). Word the Right after the protocol case to match ("… 14 finished meetings still have their audio …"); singular for one meeting.
- **Controller side**: `RecordingRetentionController` exposes `preview(for: RecordingRetention) -> RetentionPreview` (it already holds the store, live states, clock and the size lookup through `MeetingFilePresence`) and the confirm path `apply(_ retention:)`, which writes the setting and calls `requestCheck(after:)` with a few seconds.
- **Section** in `OutputSettingsView` (`Settings/OutputSettingsView.swift:31`), between "Output Folder" (`:53`) and "Protocol Generation" (`:78`): the picker with R9's five titles and the three help lines quoted in R9. The view takes only `settings` today; give it a preview provider and the apply closure the way `SpeakersSettingsView` receives its dependencies (`SettingsView.swift:95-103`, the call site at `:107`), wired in `MeetingTranscriberApp`.
- **Confirm before apply**: the picker's binding is a custom `Binding(get:set:)` (pattern at `Settings/TranscriptionSettingsView.swift:~280-292`) whose setter first compares the candidate with the stored value: Never or a longer time than the stored one applies at once without a preview, even when overdue audio is still waiting for the next check (R10). Order the values by how soon they delete (Right after the protocol, 7, 30, 90 days, Never) in one place on `RecordingRetention`. Only a shorter value asks the preview: no meeting affected → apply at once; otherwise park the pending value and the preview in an `@Observable` model the view owns, and show an `.alert` with Cancel as the default button and the destructive confirm button. Cancel drops the pending value, so the picker shows the stored one again. Test the longer-value case with an overdue meeting present: it must apply without asking.
- **Record-only**: the section stays enabled in record-only mode (spec edge case); do not apply `recordOnlyDisabled` to it.
- **Identifiers**: `A11yID.recordingRetentionPicker` and the two alert buttons where ViewInspector can reach them.
- **Tests, written first**: `RetentionPreviewTests` for each value, Keep, imports, failed meetings, Right after the protocol, singular and plural, and an empty result; `OutputSettingsViewTests` (the `find(viewWithAccessibilityIdentifier:)` then `find(ViewType.Picker.self)` then `select(value:)` locator, `SettingsInteractionTests.swift:166-183`): selecting a value that affects nothing writes the setting; selecting a longer value while an overdue meeting is present writes it without asking; selecting one that affects meetings parks it in the model and leaves the setting unchanged; confirming writes it and calls apply; cancelling leaves it.

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
- [ ] Settings → Output shows "Recordings" between "Output Folder" and "Protocol Generation" with the picker "Delete recordings automatically" (five values, default Never) and R9's three help lines; it stays enabled in record-only mode (R9).
- [ ] A value under which at least one meeting's audio would be deleted at once shows the preview with the count, the total size, "deleted for good within the next minute", that transcripts and protocols stay and what is skipped, with Cancel as the default and a destructive confirm button (R10).
- [ ] Confirming saves the value and starts a check within a minute; Cancel keeps the previous value; a value that affects no meeting, Never and a longer time than the stored one are saved without asking, also while overdue audio waits for the next check (R10, R12).
- [ ] The picker and the alert buttons have ViewInspector wiring tests located by `A11yID` constants; `RetentionPreviewTests` cover every value and skip reason and were written first (R14).
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
