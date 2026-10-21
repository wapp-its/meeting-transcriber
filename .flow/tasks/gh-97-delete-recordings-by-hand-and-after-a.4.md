---
satisfies: [R2, R4, R5, R6, R9, R11, R14]
---
# gh-97-delete-recordings-by-hand-and-after-a.4 Pure decisions: retention setting and rule, audio line, row menu and single confirmations

## Description
The pure decisions the single-row UI (task .5) and the automatic check (task .6) render or run: the stored retention setting and its rule (when a meeting's audio is due, and which audio files the check deletes now), the row's audio line and Keep badge (R2), the row's main action and menu items (R4), and the texts of the two single-meeting confirmations (R5, R6). No view, no file system, no queue: every state is tested here, so the views only render what these return (the repo's GUI testing rule 1).

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/RecordingRetention.swift` (new), `app/MeetingTranscriber/Sources/RecordingAudioLine.swift` (new), `app/MeetingTranscriber/Sources/TrashConfirmationText.swift` (new), `app/MeetingTranscriber/Sources/RecordingRowActions.swift`, `app/MeetingTranscriber/Sources/AppSettings.swift`, `app/MeetingTranscriber/Tests/RecordingRetentionRuleTests.swift` (new), `app/MeetingTranscriber/Tests/RecordingAudioLineTests.swift` (new), `app/MeetingTranscriber/Tests/TrashConfirmationTextTests.swift` (new), `app/MeetingTranscriber/Tests/RecordingRowActionsTests.swift`, `app/MeetingTranscriber/Tests/AppSettingsTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/RecordingRetention.swift, app/MeetingTranscriber/Sources/RecordingAudioLine.swift, app/MeetingTranscriber/Sources/TrashConfirmationText.swift, app/MeetingTranscriber/Sources/RecordingRowActions.swift, app/MeetingTranscriber/Sources/AppSettings.swift, app/MeetingTranscriber/Tests/RecordingRetentionRuleTests.swift, app/MeetingTranscriber/Tests/RecordingAudioLineTests.swift, app/MeetingTranscriber/Tests/TrashConfirmationTextTests.swift, app/MeetingTranscriber/Tests/RecordingRowActionsTests.swift, app/MeetingTranscriber/Tests/AppSettingsTests.swift]

### Approach
- **Setting** (R9's stored value; its Settings section is task .7): `enum RecordingRetention: String, CaseIterable, Sendable { case never, afterProtocol, days7, days30, days90 }` with `days: Int?` and a display title per case ("Never", "Right after the protocol", "After 7 days", "After 30 days", "After 90 days"). `AppSettings.recordingRetention` follows `diarizerMode` exactly: `didSet` writes the raw value (`AppSettings.swift:547`), load is `flatMap(init(rawValue:)) ?? .never` (`:869`), so an unknown stored value reads as Never; pin the raw values with a test like `AppSettingsTests.testDiarizerModeRawValuesPinJSONShape`.
- **Rule** (`RecordingRetentionRule`, pure):
  - `static func dueDate(record:, retention:, calendar:) -> Date?`: nil for Never, an import, a kept meeting or no recording date; Right after the protocol → the recording date (due as soon as it is eligible); days → recording date plus that many days in `calendar`.
  - `static func audioToDelete(record:, liveState: JobState?, retention:, now:) -> [MeetingFile]`: empty unless origin is recorded, the outcome is finished and either a protocol is listed or protocol generation was off (A1), the live job (when the queue still lists it) is `.done`, Keep is off, `excludedFromAutomaticDeletion` is off, no deletion is incomplete or pending, and `dueDate <= now`; then the owned audio roles still marked present. Every other case returns empty (R11's error list).
- **Audio line** (`RecordingAudioLine`, pure): input the record (optional), the live state, an `AudioOnDisk` value (`presentCount`, `unreachableCount`, `totalCount`, `bytes` of the present ones) resolved by the caller with task .1's probe, the retention, `now`, a `Calendar` and a `Locale`; output the line text, the Keep badge flag, and the incomplete reason when there is one. The exact strings are R2's; the mockup's samples are "Audio · 412 MB · kept until the speakers are named", "Audio · 286 MB · deleted automatically on 15 Nov", "Audio · your imported file, never deleted by the app". For an incomplete deletion the mockup shows "Deletion incomplete: 1 file is on a drive that is not connected" above "Audio · 2 of 3 files moved to the Trash"; the reason text comes from task .3's per-file outcome, counted ("1 file is …", "2 files are …"). When nothing is present but something is unreachable the line is "Audio · on a drive that is not connected", never "Audio not found" (R2). Add R2's no-protocol line "Audio · 286 MB · kept, no protocol was saved" and R6's "Audio · 2 of 3 files moved to the Trash" for an incomplete meeting deletion. Sizes through `ByteCountFormatter` with `.file` style; dates as day and abbreviated month in the given locale (tests pin `en_GB`, which reads "15 Nov").
- **Row actions** (extend gh-170's `RecordingRowActions`, `RecordingRowActions.swift:18-108`): add an input describing the record (none; origin; failed; Keep; any audio present or unreachable, as opposed to confirmed gone; incomplete; a deletion pending) and `MenuItem` cases `keep(checked: Bool, enabled: Bool)`, `moveAudioToTrash(enabled: Bool)`, `moveMeetingToTrash(enabled: Bool)`, listed after Regenerate Protocol… in the mockup's order (Open Protocol, Open Transcript, Show in Finder, Regenerate Protocol…, Keep (Never Delete Automatically), Move Audio to Trash…, Move Meeting to Trash…). R4's rules decide presence and enabled state. `MainAction` gains `retryDeletion`, which wins over every other main action while a deletion is incomplete; this extends gh-170's main-button set (its R6) on purpose.
- **Confirmation texts** (`TrashConfirmationText`, pure): title, message lines and the confirm button for one meeting. The mockup's audio confirmation: title "Move the audio of “Budget review” to the Trash?"; "3 audio files (286 MB) go to the Trash. The transcript and the protocol stay, and Regenerate Protocol keeps working."; "Without the audio you cannot transcribe this meeting again or identify its speakers again. Voice profiles learned from it stay."; then the file names; buttons "Cancel" and "Move to Trash". The meeting confirmation has no mockup board: follow R6's elements in the same voice ("Move “Budget review” to the Trash?", its audio with size, transcript and protocol go to the Trash and the meeting leaves the list, voice profiles stay, and for an import that the imported file stays where it is).
- **Tests, written first**: the rule over every outcome, origin, Keep, a recording from before this feature, incomplete, pending, a missing recording date, each retention value and the boundary `now == dueDate`; the audio line for every R2 case, a past due date ("deleted automatically at the next check"), "Audio not found" and an all-unreachable meeting; the row actions for every `JobState` crossed with no record, recorded, import, failed, kept, no audio left, audio only unreachable (Keep and Trash still offered) and incomplete, asserting order and enabled state; the confirmation texts for one and several files, singular and plural, an import, and a meeting without a transcript or protocol.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/RecordingRowActions.swift` - the gh-170 decision this extends
- `app/MeetingTranscriber/Tests/RecordingRowActionsTests.swift` - its table-style tests
- `app/MeetingTranscriber/Sources/AppSettings.swift:40-60`, `:540-555`, `:860-875` - the `diarizerMode` pattern

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/PipelineJob.swift:1-35` - `JobState` and `isTerminal`
- `app/MeetingTranscriber/Tests/AppSettingsTests.swift` - raw-value pin test

### Key context
- Pure means no `FileManager`, no `Date()` and no SwiftUI import: presence, sizes, the clock, calendar and locale come in as inputs.
- `JobState` has seven cases; switch without `default` so a new state cannot slip through the rule.
## Acceptance
- [ ] `AppSettings.recordingRetention` stores one of Never, Right after the protocol, After 7, 30 or 90 days, defaults to Never and reads an unknown stored value as Never; a test pins the raw values (R9).
- [ ] The retention rule returns a meeting's owned audio files only when it is recorded, finished with a protocol saved or protocol generation off, not live in another state, not kept, not incomplete and due; it returns nothing for every case in R11's error list (R11, A1).
- [ ] The audio line returns R2's text for each meeting state, with the Keep badge, "Audio not found" only for audio confirmed gone, the not-connected text for unreachable audio, the passed-date wording and the incomplete-deletion text of R6 (R2, R6).
- [ ] The row actions list Keep, Move Audio to Trash… and Move Meeting to Trash… after Regenerate Protocol… with R4's presence and enabled rules, and make Retry Deletion the main action while a deletion is incomplete (R4, R5, R6, A2, A3, A4).
- [ ] The confirmation texts carry every element of R5 and R6, singular and plural (R5, R6).
- [ ] All new tests were written before the implementation and pass; none of the new types imports SwiftUI or touches the file system (R14).
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
