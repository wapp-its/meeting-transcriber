---
satisfies: [R1, R2, R4, R5, R6, R8]
---
# gh-13-transcriptions-window.4 Transcriptions window and its menu item

## Description
The "Transcriptions" window itself and the menu item that opens it: a searchable list of every entry with Open, Show in Finder, Retry and Remove, the scene, the missing-file message, and the privacy pin against the debug RPC allowlists. Last because it composes everything tasks .1-.3 built. See spec R1, R4, R5, R6, R8 and decisions A4, A6, D3.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/TranscriptionsView.swift` (new), `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/MenuBarView.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift` (new), `app/MeetingTranscriber/Tests/TranscriptionsWindowPrivacyTests.swift` (new), `app/MeetingTranscriber/Tests/MenuBarViewTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/TranscriptionsView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift, app/MeetingTranscriber/Tests/TranscriptionsWindowPrivacyTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift]

### Approach
- `TranscriptionsView: View` with stored properties only, as `SettingsView` takes them (`Sources/MeetingTranscriberApp.swift:255-277`): `entries: [TranscriptionEntry]`, `query: Binding<String>`, `canRetry: (UUID) -> Bool`, `onOpen: (URL) -> Bool`, `onReveal: (URL) -> Bool`, `onRetry: (UUID) -> Void`, `onRemove: (UUID) -> Void`, and `static let windowID = "transcriptions"`. The query is a binding, not `@State`, so a test can drive and read it (CLAUDE.md "GUI Testing", layer 2).
- Layout: a search `TextField` (`A11yID.transcriptionsSearchField`) above a `List` of `TranscriptionList.matching(entries, query:)`. Empty states: "No transcriptions yet" when `entries` is empty, "No transcriptions match" when the filter leaves nothing. Each row: title; a detail line of app · date and time (`Date.formatted(date: .abbreviated, time: .shortened)`) · duration (`formattedTime`, `Sources/SpeakerNamingView.swift:8-12`), each part "—" when nil; status text and symbol from `JobMenuSummary.status(state:hasWarnings:progress:)` with `state.label` as progress and `symbol(state:hasWarnings:)`; the error text (red) for a failed entry, the warnings (orange) for done-with-warnings; buttons "Open" and "Show in Finder" when `fileToOpen` exists, "Retry" when failed and `canRetry(id)`, "Remove" when failed. Identifiers are index-based over the filtered list: `transcriptionOpenButton(i)`, `transcriptionRevealButton(i)`, `transcriptionRetryButton(i)`, `transcriptionRemoveButton(i)`, following `A11yID.jobRetryButton` (`Sources/A11yID.swift:55-60`). A failed Open/Reveal (closure returned false) shows a one-line "The file was moved or deleted." in the window (view `@State` is fine for that message).
- Put the row and the detail-line formatting in small hoisted properties or helper views; a pure `static func detailLine(for:)` lets a unit test pin the "—" rule without ViewInspector.
- The App's `onOpen`/`onReveal` closures call `TranscriptionFileOpener.perform` (task .2) with `scopeRoot: appState.settings.effectiveOutputDir` and the actions `NSWorkspace.shared.open(url)` / `NSWorkspace.shared.activateFileViewerSelecting([url])`, returning its result.
- Scene: a new `private var transcriptionsWindow: some Scene` in `MeetingTranscriberApp`, its own property per the type-check note (`:111-118`), added to `body`: `Window("Transcriptions", id: TranscriptionsView.windowID)` with a `.defaultSize` (about 760 × 520), resizable (no `.contentSize`). Content reads `appState.pipeline.transcriptionEntries`, binds an App-level `@State private var transcriptionsQuery = ""`, wires `canRetry`/`onRetry` to `appState.pipeline.canRetryJob`/`retryJob`, `onRemove` to `removeFailedJob`, and calls `appState.pipeline.prepareTranscriptionsWindow()` in `.onAppear`.
- Menu item: `MenuBarView` gains `var onShowAllTranscriptions: () -> Void = {}` (default for the existing test constructions) and a button "All Transcriptions..." (`systemImage: "list.bullet.rectangle"`, `.keyboardShortcut("t")`, `A11yID.allTranscriptionsMenuItem`), always visible, placed right after the job lines and before `protocolActions`. The App passes `{ bringWindowToFront(id: TranscriptionsView.windowID) }` (`:384-393`).
- Do not add the window id to any allowlist in `DebugRPCServer+Screenshot.swift:27`, `DebugRPCServer+UITree.swift:77`, `DebugRPCServer+UIPress.swift:78`, `DebugRPCServer+UIType.swift:77`; `TranscriptionsWindowPrivacyTests` (wrapped in `#if !APPSTORE`, since those files are) pins that `TranscriptionsView.windowID` is in none of the four sets.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:79-160,227-299,384-407` — scenes, menu wiring, `bringWindowToFront`, `openProtocolsFolder`
- `app/MeetingTranscriber/Sources/DebugRPCServer+Screenshot.swift:11-38` — allowlist rationale and helper
- `app/MeetingTranscriber/Tests/TranscriptionSettingsCustomModelTests.swift:80-105` — `setInput` on a located `TextField`
- `app/MeetingTranscriber/Tests/ViewInspectorIdentifierTests.swift` — two-step identifier lookup
- `app/MeetingTranscriber/Sources/TranscriptionList.swift` — from task .2

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift` — a plain settings-style view for layout tone
- `app/MeetingTranscriber/Tests/MenuBarViewTests.swift:308-335` — callback-button test shape

### Key context
- The window shows titles and participants: it stays off every RPC allowlist (D3), and no identifier may carry a title, participant or path.
- `prepareTranscriptionsWindow()` starts the pipeline when it is not running yet, which may resume interrupted jobs; that is intended (A6). macOS may restore the window at launch, which then does the same.
- A ViewInspector tap that writes `@State` cannot be asserted (CLAUDE.md "GUI Testing"); assert through the injected closures and binding.
- Opening files and the window's look are manual QA (no NSWorkspace call in tests); the opener itself is tested in task .2.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<your scratch dir>/home swift test --parallel --filter 'TranscriptionsViewTests|TranscriptionsWindowPrivacyTests|MenuBarViewTests|MenuBarJobMenuTests|TranscriptionListTests|PipelineControllerTranscriptionsTests' > <your scratch dir>/t4-tests.log 2>&1` and read the log.
- `./scripts/lint.sh` with the pinned tools from `scripts/tool-versions.sh`.
- `./scripts/pre-push.sh --with-appstore` (release build and App Store variant; the privacy test must compile out cleanly there).
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<your scratch dir>/home swift test --parallel > <your scratch dir>/t4-full.log 2>&1` once at the end; compare failures against the known environmental ones (model downloads, dark-mode snapshot flake) before calling it red.
## Acceptance
- [ ] The menu shows "All Transcriptions..." with key equivalent ⌘T at all times; tapping it (located by `A11yID.allTranscriptionsMenuItem`) calls `onShowAllTranscriptions` (R1).
- [ ] The scene `Window("Transcriptions", id: "transcriptions")` exists, its content calls `prepareTranscriptionsWindow()` on appear, and the menu callback opens it through `bringWindowToFront` (R1).
- [ ] Entering text in the search field (located by `A11yID.transcriptionsSearchField`) writes the binding; a view built with a query shows only matching rows, and "No transcriptions match" when none match (R4).
- [ ] A row's Open and Show in Finder pass the entry's protocol (or transcript) URL to their closures; an entry with neither file has neither button (R5).
- [ ] The App's Open and Show in Finder closures go through `TranscriptionFileOpener` with the current output folder as scope root, and a false result shows the moved-or-deleted message (R5).
- [ ] A failed row shows its error text, Retry only when `canRetry` is true, and Remove calling `onRemove` with its id; a done row has no Retry or Remove (R6).
- [ ] An entry without app, date or duration shows "—" for each (R2).
- [ ] `TranscriptionsView.windowID` is in none of `screenshotAllowedWindowIDs`, `uiTreeAllowedWindowIDs`, `uiPressAllowedWindowIDs`, `uiTypeAllowedWindowIDs` (R8).
- [ ] Tests, lint and `./scripts/pre-push.sh --with-appstore` pass; the full suite shows no new failure beyond the known environmental ones.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
