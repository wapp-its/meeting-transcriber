---
satisfies: [R3, R7, R14]
---
# gh-97-delete-recordings-by-hand-and-after-a.8 Multi-select, footer and docs

## Description
The last slice: several rows can be selected and moved to the Trash with one confirmation (R7), the window gets its footer (R3), and the docs are brought in line with what the spec built. Multi-select comes last because it changes the list's structure (`List(selection:)` and the selection context menu), which is easier on a window whose single-row actions are already proven.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/TranscriptionsView.swift`, `app/MeetingTranscriber/Sources/TranscriptionsSelection.swift` (new), `app/MeetingTranscriber/Sources/TrashConfirmationText.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Sources/RecordingFileSuffix.swift`, `docs/architecture-macos.md`, `docs/automation-api.md`, `README.md`, `app/MeetingTranscriber/Tests/TranscriptionsSelectionTests.swift` (new), `app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift`, `app/MeetingTranscriber/Tests/TrashConfirmationTextTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/TranscriptionsView.swift, app/MeetingTranscriber/Sources/TranscriptionsSelection.swift, app/MeetingTranscriber/Sources/TrashConfirmationText.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Sources/AllRecordingsActions.swift, app/MeetingTranscriber/Sources/RecordingFileSuffix.swift, docs/architecture-macos.md, docs/automation-api.md, README.md, app/MeetingTranscriber/Tests/TranscriptionsSelectionTests.swift, app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift, app/MeetingTranscriber/Tests/TrashConfirmationTextTests.swift]

### Approach
- **Selection**: hold `Set<UUID>` in an `@Observable` `TranscriptionsSelection` the view owns (same reason as task .5's confirmation model), and turn the plain `List { ForEach }` (`TranscriptionsView.swift:138-151`) into `List(selection:)`, as `AppPickerView.swift:192` already does for a single selection on macOS 14; a `Set` binding makes it multi-select, with Shift and Command selection built in.
- **Menus**: replace the per-row `.contextMenu` with `.contextMenu(forSelectionType: UUID.self)`: one id → the row's full menu from task .4 (R4); several → only Move Audio to Trash… and Move Meeting to Trash…, applied to the selection. The "…" button on a row keeps acting on that row alone.
- **Plan, pure** (in `TranscriptionsSelection.swift`): from the selected entries, their records and audio sizes, and an action, return the meetings it applies to (R4's rules per meeting), how many are left out, the names of kept meetings, whether imports are among them, and the total audio size. The action is disabled when it applies to none.
- **Confirmation for several** (extend `TrashConfirmationText`): the mockup's "Move 3 meetings to the Trash?"; "Their audio (1.4 GB), transcripts and protocols go to the Trash, and the meetings leave this list."; "“Strategy offsite” is marked Keep. Keep only stops automatic deletion, so it goes too."; "Voice profiles learned from these meetings stay."; buttons "Cancel" and "Move to Trash". Add R7's lines for meetings left out and for imports whose files stay; the audio variant says that transcripts and protocols stay. Per-meeting failures follow task .3: each failed meeting stays as "Deletion incomplete".
- **Footer** below the list (`body`, `TranscriptionsView.swift:67-71`): the mockup's "8 recordings · audio 1.9 GB · recordings are deleted automatically after 30 days (Settings → Output)"; "… right after the protocol …" for that value; no third part with Never; "3 of 8 selected" replaces the count while rows are selected. Count and size cover the rows shown by the current search; sizes come from the `RowAvailability` cache.
- **Docs**: `docs/architecture-macos.md` gets a short section on the meeting file record and the deletion rules near "Output Structure" (`:691`) and rows for the new types in its file tables (near `:117`, `:175`, `:210`, `:377`), and its claim of a recordings retention policy (`:651-655`) is replaced by the real one; `docs/automation-api.md` adds a meeting moved to the Trash to the 404 reasons of `GET /v1/jobs/<id>` (`:154-173`); the comment at `RecordingFileSuffix.swift:19-21` stops saying the mic track stays in staging (all three tracks move); `README.md:282` names the Recordings section of the Output tab. `CLAUDE.md` and `AGENTS.md` stay unchanged.
- **Tests, written first**: `TranscriptionsSelectionTests` for mixed selections (recorded, import, failed, no record, kept, live), the left-out count, imports and the disabled case; `TrashConfirmationTextTests` for the several-meetings texts; `TranscriptionsViewTests` for the footer text with and without a selection and for each retention value, and the selection confirmation landing in the model.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/TranscriptionsView.swift:60-160`, `:240-260` - body, list, row menu
- `app/MeetingTranscriber/Sources/AppPickerView.swift:180-200` - `List(selection:)` in this app
- `docs/architecture-macos.md:640-700` - the wrong retention sentence and "Output Structure"
- `docs/automation-api.md:150-175` - the 404 list

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/RecordingFileSuffix.swift` - the stale comment
- `README.md:270-290` - the Output tab description

### Key context
- ViewInspector cannot drive a `List` selection or a selection context menu; set the selection through the `@Observable` model in tests and assert the plan and the footer, and leave the click itself to manual checking, as CLAUDE.md's GUI testing section allows.
- A row's inline buttons keep working inside `List(selection:)`; check that a click on the "…" button does not change the selection unexpectedly.
- The docs live in a public fork: describe the feature, not this spec or its task ids.

## Acceptance
- [ ] Rows can be selected with Shift and Command; with several selected the menu offers only the two Trash actions, applied after one confirmation that names kept meetings, says how many were left out and that imported files stay; the action is disabled when it applies to none; a failed meeting in the batch stays as "Deletion incomplete" (R7).
- [ ] The footer shows the count and total audio size of the rows shown, the retention sentence when the setting is not Never, and "N of M selected" while rows are selected (R3).
- [ ] `docs/architecture-macos.md`, `docs/automation-api.md`, the `RecordingFileSuffix` comment and `README.md` describe the record, the deletion rules and the 404 after Move Meeting to Trash; the false retention sentence is gone; `CLAUDE.md` and `AGENTS.md` are unchanged.
- [ ] `TranscriptionsSelectionTests` and the new view and text tests were written before the implementation and pass; the spec's quick command passes (R14).


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
