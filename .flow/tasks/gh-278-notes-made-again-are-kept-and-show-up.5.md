---
satisfies: [R4, R7, R8, R9]
---
# gh-278-notes-made-again-are-kept-and-show-up.5 Row actions: Retry Meeting Notes, Write Notes and Finder with all of a meeting's files

## Description
The row's actions: Retry Meeting Notes as the main button and the first menu item for a meeting whose notes failed (R4), "Write Notes…" for a meeting without notes (R8, the row part), and Finder actions that show all of a meeting's files and the folder the notes are in (R7). It needs nothing from the other tasks: the entry already knows `hasRetryableMeetingNotes`.

**Size:** M
**Files:** `Sources/RecordingRowActions.swift`, `Sources/TranscriptionsView+RowLabels.swift`, `Sources/TranscriptionsView.swift`, `Sources/AllRecordingsActions.swift`, `Sources/MeetingTranscriberApp.swift`, `Sources/A11yID.swift`; tests `Tests/RecordingRowActionsTests.swift`, a new `Tests/TranscriptionsViewTests+RowActions.swift`
**Touches:** [app/MeetingTranscriber/Sources/RecordingRowActions.swift, app/MeetingTranscriber/Sources/TranscriptionsView+RowLabels.swift, app/MeetingTranscriber/Sources/TranscriptionsView.swift, app/MeetingTranscriber/Sources/AllRecordingsActions.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/RecordingRowActionsTests.swift, app/MeetingTranscriber/Tests/TranscriptionsViewTests+RowActions.swift]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first: the main-button and menu tests fail on today's code.
1. **Actions** (`Sources/RecordingRowActions.swift:10-44,157-207`): new `MainAction.retryMeetingNotes` and `MenuItem.retryMeetingNotes` (the existing `.retry` retries an errored job, `canRetry`, and stays). `mainAction` picks it for a finished entry with `hasRetryableMeetingNotes`; `menuItems` lists it first, in the "…" and the right-click menu alike. `.regenerate(enabled:)` also learns whether the meeting has notes (the row's `FilesOnDisk`, `:140-149`), for the "Write Notes…" title.
2. **Labels and ids** (`Sources/TranscriptionsView+RowLabels.swift:31-40,51-66,78-95`; `Sources/A11yID.swift`, beside `jobNotesRetryButton` at `:261`): "Retry Meeting Notes"; "Write Notes…" without notes, "Regenerate Notes…" with.
3. **Retry action**: `AllRecordingsActions` (`Sources/AllRecordingsActions.swift:21-31`) gets `retryMeetingNotes: (UUID) -> Bool`, wired at `Sources/MeetingTranscriberApp.swift:515-530` to the menu bar's action (`pipelineQueue.retryMeetingNotes(id:)`, as `Sources/MenuBarView+Jobs.swift:134-137` calls it). On `false` the queue has added its warning, which the row then shows, as in the menu bar. `perform` at `Sources/TranscriptionsView.swift:413-440` handles both the main button and the menu item.
4. **Show in Finder** (`AllRecordingsActions.revealFile`, `:163-167`, and the row's `.showInFinder` at `Sources/TranscriptionsView.swift:433`): reveal the notes, the transcript and every report in `FilesOnDisk.reports` that still exists, in one call to an injected `([URL]) -> Void` that wraps `NSWorkspace.activateFileViewerSelecting` (today's `reveal` is `(URL) -> Bool`; give it a multi-file variant). None left → "The file was moved or deleted." as today. Files in different folders each show in their folder (one call does that).
5. **Open Notes Folder** (`MeetingTranscriberApp.swift:526`, `AllRecordingsActions.openFolder` `:171-177`): open `<output folder>/protocols` and create it when missing. `openFolder` starts the security scope on its argument; keep the scope on the output root and create `protocols` inside it. Reuse a constant for the folder name if one exists (`Sources/PipelineQueue+Stages.swift:162,1092` and `Sources/RegenerateProtocolView.swift:327` spell it out).
6. Keep `TranscriptionsView.facts(for:)` (`:255-285`) under the 300 ms type-check limit (`Package.swift:77-80`): add inputs through a small struct, not more inline calls.

Tests:
- `Tests/RecordingRowActionsTests.swift:152,214` (`assertMainAction`, `assertMenu`): finished with retryable notes → main "Retry Meeting Notes" and first menu item; the same job waiting again after a retry → no retry; a history-only entry with failed notes → no retry; an errored job → `.retry` as today; no notes → "Write Notes…"; notes → "Regenerate Notes…".
- Wiring (ViewInspector, the injected-closure pattern in `Tests/TranscriptionsViewTests.swift:55,63,152,310-312`): the row's Retry calls the closure with the job's id, and a `false` answer leaves the warning on the row; Show in Finder passes notes, transcript and "<meeting> (Short 2).md" in one call and leaves out a file that is gone; Open Notes Folder opens `<output>/protocols` and creates it when missing (temporary folder).

### Investigation targets
**Required** (read before coding):
- `Sources/RecordingRowActions.swift` — actions, menu items, `FilesOnDisk`
- `Sources/TranscriptionsView.swift:250-290,395-445` — `facts`, `perform`
- `Sources/AllRecordingsActions.swift` — closures, `revealFile`, `openFolder`
- `Sources/MeetingTranscriberApp.swift:505-535` — the wiring
- `Tests/RecordingRowActionsTests.swift:140-230` — the assertion helpers

**Optional** (reference as needed):
- `Sources/TranscriptionFileOpener.swift` — the file-gone message
- `docs/architecture/gui-testing.md` — A11yID, wiring tests, snapshots
## Acceptance
- [ ] A finished row with retryable notes has "Retry Meeting Notes" as its main button and first menu item, calling the menu bar's retry; a refused retry's warning shows on the row; a history-only or waiting row offers none.
- [ ] A meeting without notes reads "Write Notes…", one with notes "Regenerate Notes…".
- [ ] Show in Finder selects notes, transcript and every existing report in one call; with none left the row says "The file was moved or deleted."
- [ ] Open Notes Folder opens `<output folder>/protocols`, created when missing, under the output folder's security scope.
- [ ] Each new or changed test fails on the code before this task.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
