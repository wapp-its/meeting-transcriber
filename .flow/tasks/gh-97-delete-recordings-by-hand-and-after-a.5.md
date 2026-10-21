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
- **Inputs**: extend `AllRecordingsActions` (`AllRecordingsActions.swift:7-60`, and `.noop` at `:51`) with `meetingFiles: (UUID) -> MeetingFileRecord?`, `audioOnDisk: (TranscriptionEntry) -> RecordingAudioLine.AudioOnDisk?`, `moveAudioToTrash`, `moveMeetingToTrash`, `retryDeletion`, `setKeep`, and `retention: () -> RecordingRetention`. Wire them in `MeetingTranscriberApp.allRecordingsActions` (`MeetingTranscriberApp.swift:199-224`) to the controller actions of task .3 and to `settings.recordingRetention`.
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
- [ ] The "…" menu and the right-click menu list Keep (Never Delete Automatically) with its check mark, Move Audio to Trash… and Move Meeting to Trash… after Regenerate Protocol…, present and enabled as task .4 decides; the gh-170 menu test is updated to the new list (R4).
- [ ] Each Trash item asks first with task .4's text; Cancel changes nothing; confirming runs the action and the row then shows the new audio line, disappears (Move Meeting) or shows "Deletion incomplete" with a Retry Deletion main button (R5, R6, D7).
- [ ] Keep toggles the meeting's Keep mark (R8).
- [ ] Every new control has one ViewInspector wiring test located by an `A11yID` constant; All Recordings stays off every `/ui` and screenshot allowlist (R14).
- [ ] The spec's quick command passes.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
