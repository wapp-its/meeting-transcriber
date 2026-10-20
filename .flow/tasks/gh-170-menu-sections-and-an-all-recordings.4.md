---
satisfies: [R3, R5, R6, R7, R10]
---
# gh-170-menu-sections-and-an-all-recordings.4 The All Recordings window: title, toolbar, rows with a main button and a "…" menu

Touches: app/MeetingTranscriber/Sources/TranscriptionsView.swift, app/MeetingTranscriber/Sources/AllRecordingsActions.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MenuActions.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift, app/MeetingTranscriber/Tests/TranscriptionsWindowPrivacyTests.swift, .github/README.md, docs/automation-api.md

## Description
Today's Transcriptions window becomes "All Recordings": a toolbar with the search, "Open Protocols Folder" and "Regenerate from File…", and rows whose buttons come from task .3's decision. "Open Protocols Folder" leaves the menu here, because this is where it gets its new home. The regenerate sheet itself is task .5; in this task both regenerate entry points call one `regenerate(entry?)` action whose production closure opens today's Regenerate Protocol window, an interim that .5 replaces.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/TranscriptionsView.swift`, `app/MeetingTranscriber/Sources/AllRecordingsActions.swift` (new), `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/MenuBarView.swift`, `app/MeetingTranscriber/Sources/MenuActions.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift`, `app/MeetingTranscriber/Tests/MenuBarViewTests.swift`, `app/MeetingTranscriber/Tests/TranscriptionsWindowPrivacyTests.swift`, `.github/README.md`, `docs/automation-api.md`
**Touches:** [app/MeetingTranscriber/Sources/TranscriptionsView.swift, app/MeetingTranscriber/Sources/AllRecordingsActions.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MenuActions.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift, app/MeetingTranscriber/Tests/TranscriptionsWindowPrivacyTests.swift, .github/README.md, docs/automation-api.md]

### Approach
- **Title and id.** The scene `Window("Transcriptions", id: TranscriptionsView.windowID)` (`MeetingTranscriberApp.swift:353-368`) gets the title "All Recordings"; the id `"transcriptions"` and the type names stay (nothing user-visible depends on them, `bringWindowToFront` at `:184` and `TranscriptionsWindowPrivacyTests` read the id, and a rename is not asked for). Comments that say "Transcriptions window" in the touched files say "All Recordings window".
- **Actions value.** `AllRecordingsActions` (own file, the shape of `MenuActions`): `openProtocol(URL) -> Bool` and `openTranscript(URL) -> Bool` (both through `TranscriptionFileOpener`, as `openTranscriptionFile` at `:523`), `reveal(URL) -> Bool` (`:532`), `regenerate(TranscriptionEntry?)`, `retry(UUID)`, `remove(UUID)` (`PipelineController.removeFailedJob`, which already handles a history-only record), `dismiss(UUID)` (`pipelineQueue.removeJob`, as the menu's Dismiss at `:187`), `cancel(UUID)` (`pipelineQueue.cancelJob`), `nameSpeakers(UUID)` (A5: set `appState.selectedNamingJobID` to the row's job, then `bringWindowToFront(id: "speaker-naming")`), `openProtocolsFolder()` (the App's `openProtocolsFolder`, `:506-512`, moved as is: creates the folder, opens it, no message), `canRetry(UUID) -> Bool`, and `filesOnDisk(TranscriptionEntry) -> RecordingRowActions.FilesOnDisk` (`FileManager.fileExists` on both URLs; `protocolHoldsFullTranscript` via `ProtocolGenerator.fullTranscript(in:)`, `ProtocolGenerator.swift:211`, read only when the `.txt` is absent). Interim production `regenerate`: `bringWindowToFront(id: RegenerateProtocolView.windowID)` with a comment pointing at task .5. The window's production value is built next to the menu's in `MeetingTranscriberApp`.
- **Toolbar.** `.toolbar { }` on the window's root with the search `TextField` (keep `A11yID.transcriptionsSearchField`, the App-held `transcriptionsQuery` binding `:89-93` and `TranscriptionList.matching` untouched), "Open Protocols Folder" (`A11yID.recordingsOpenFolderButton`) and "Regenerate from File…" (`A11yID.recordingsRegenerateFromFileButton`, calls `regenerate(nil)`). No window shortcuts.
- **Rows** (`TranscriptionsView.swift:117-134`, `:173-195`): the text column stays; `fileActions`/`failureActions` are replaced by one main button from `RecordingRowActions.mainAction` (`A11yID.recordingMainButton(index)`, the label from the action: "Cancel", "Name Speakers", "Open Protocol", "Open Transcript", "Retry", "Remove"; absent when nil) and a "…" `Menu` (`A11yID.recordingMoreButton(index)`, disabled when the item list is empty) whose content is one `@ViewBuilder rowMenu(entry, index)` built from `RecordingRowActions.menuItems(state:onDisk:canRetry:)` with `onDisk` from `actions.filesOnDisk(entry)` at build time; the same builder is attached as `.contextMenu` on the row's `HStack`, so the two menus are the same list by construction. Each item carries an index-addressed id (`A11yID.recordingMenuOpenProtocol(index)`, `...OpenTranscript`, `...ShowInFinder`, `...Regenerate`, `...Retry`, `...Remove`, `...Dismiss`). A false result from open/reveal sets `TranscriptionsFileNotice.fileMissing` as today (`:85`); Show in Finder reveals the protocol, else the transcript.
- **Menu.** Remove "Open Protocols Folder" from `MenuBarView` (`:342-346` before task .2's move; the Recordings section after it) and `MenuActions.openProtocolsFolder`; move its tests (`MenuBarViewTests.swift:202`, `:374`) to `TranscriptionsViewTests` as the toolbar button's wiring test.
- **Docs.** `.github/README.md:27` and `docs/automation-api.md:169` name the Transcriptions window; say "All Recordings window" (and keep Cmd-T). `CLAUDE.md` is not edited in this fork.
- **Tests** (`TranscriptionsViewTests`, by `A11yID`): one wiring test per control: the main button for each `MainAction` (the Name Speakers one asserts the row's job id reaches the closure, A5; the Cancel one asserts `cancel` ran), the "…" menu's items (find the `Menu`, then each item's button by id, tap, assert the closure argument), both toolbar buttons, and a test that the `Menu` holds exactly the items `RecordingRowActions.menuItems` returns for that row (parity with the context menu rests on the shared builder plus task .3's tests; no right-click simulation). Keep the search and "The file was moved or deleted." tests; `TranscriptionsWindowPrivacyTests` stays green with the same id.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/TranscriptionsView.swift` - the whole view, its notice type and its row
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:149-198,353-368,504-535` - the menu value, the scene, the file actions
- `app/MeetingTranscriber/Sources/RecordingRowActions.swift` - task .3's decision (read its tests too)
- `app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift` - the wiring-test shape to extend

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift` - `prepareTranscriptionsWindow`, `canRetryJob`, `removeFailedJob`
- `app/MeetingTranscriber/Sources/AppState.swift:30` - `selectedNamingJobID`, which the naming window binds to (`MeetingTranscriberApp.swift:415-434`)
- `app/MeetingTranscriber/Tests/TranscriptionsWindowPrivacyTests.swift` - the allowlist pin that must stay green

### Key context
- `/ui/tree` and `/ui/press` allowlists are `["settings"]` (`DebugRPCServer+UITree.swift:77`, `+UIPress.swift:78`); the window shows titles and participants and stays off them (R10).
- SwiftUI builds `Menu` and `.contextMenu` content when the menu opens, so the per-row existence reads run on open, not on every redraw; if measurement shows the content is built eagerly, resolve `filesOnDisk` once per `entries` change instead. The history holds up to 1000 records (`TerminalJobStore`), so a per-redraw `fileExists` on every row is the case to avoid.
- A history-only failed job becomes retryable once `prepareTranscriptionsWindow` has loaded the queue (`PipelineController+Transcriptions.swift:14-16`); the main button follows `canRetry` at render time, as today's Retry button does.
- A state a tap writes must be a reference type for ViewInspector to see it (`TranscriptionsFileNotice` is the pattern; CLAUDE.md § GUI Testing rung 2).

### Acceptance
- [ ] The window opened by "All Recordings…" is titled "All Recordings", with the same window id and the same list source and search as before; "Open Protocols Folder" is no longer in the menu (R3).
- [ ] The toolbar holds the search field (unchanged matching), "Open Protocols Folder" (same behaviour as the old menu item: creates a missing folder, opens it, no message on failure) and "Regenerate from File…", which calls the regenerate action with no meeting (R5).
- [ ] Each row shows exactly the main button `RecordingRowActions.mainAction` returns for it, wired to the matching action; a finished job with neither file has none; the row's Name Speakers selects that job before opening the naming window (R6, A5).
- [ ] Each row has a "…" button whose menu lists exactly `RecordingRowActions.menuItems` for the row, with the same builder attached as the row's context menu; an item whose file is missing at build time is left out and Regenerate Protocol… is disabled only without a usable transcript source; a file gone after the menu was built still shows "The file was moved or deleted." (R7, A6).
- [ ] One ViewInspector wiring test per new or moved control, located by its `A11yID` constant: every main-button kind, every "…" item, both toolbar buttons; `TranscriptionsWindowPrivacyTests` still pins the window off the `/ui/tree` and `/ui/press` allowlists (R10).
- [ ] `.github/README.md` and `docs/automation-api.md` name the All Recordings window; `CLAUDE.md` is untouched; the spec's Quick command is green; `./scripts/lint.sh` is clean.

## Acceptance
- [ ] TBD

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
