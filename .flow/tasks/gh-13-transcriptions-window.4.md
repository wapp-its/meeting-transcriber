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
The menu bar now has "All Transcriptions..." (key equivalent Cmd-T while the menu is open), which opens a resizable "Transcriptions" window listing every job the app knows, newest first, with a search over titles and participants, Open and Show in Finder on each entry with a protocol or transcript, and Retry (where the pipeline accepts it) plus Remove on failed entries. Opening the window starts the pipeline the way a file import does, so a failed job from an earlier session can be retried there.

Tier: session (jev-unavailable(no_key)) -> explicit invocation opus at xhigh (actual: claude-opus-5-5)

stage: impl-review - ran [2026-10-08T13:10:25Z..2026-10-08T13:17:07Z]

The review ran on codex gpt-5.6-sol at xhigh with three draws (correctness, contracts, integration), each SHIP; the receipt records verdict SHIP, spec codex:gpt-5.6-sol:xhigh (receipt /tmp/impl-review-receipt-372726e60d63-gh-13-transcriptions-window.4.json, fan-out rid 32db7f6b6bad4aca977c40ee2b47ec97). The correctness and integration draws raised one shared P2 finding, kept in the merged document and declined (see Decisions). With FLOW_VALIDATE_REVIEW=1 the finalize held the phase lease, the validator had nothing to dispatch on a SHIP round, and the lease was released. The contracts draw wrote "No surviving findings.", which the merge-plan parser refused, so the round was finalized through the merged-file route with the same content. The reviewers ran under CODEX_SANDBOX=workspace-write (owner override) and wrote nothing into the tracked tree.

Acceptance criteria and the tests that pin them (focused run at 5f0abe42: 101 tests, suite_rc 0, /private/tmp/gh13/t4-verify.log):
- R1 menu item. MenuBarViewTests.testAllTranscriptionsItemIsAlwaysShownAndCallsItsCallback finds the item by A11yID.allTranscriptionsMenuItem while recording with a job line and while idle with none, reads its label "All Transcriptions...", and its tap calls onShowAllTranscriptions. The Cmd-T key equivalent (`.keyboardShortcut("t")` in MenuBarView.allTranscriptionsItem) is verified by reading the code; ViewInspector 0.10.5 lists keyboardShortcut among its unsupported APIs, and menu-bar dropdown interaction is manual QA per the project's GUI testing rules.
- R1 scene. MeetingTranscriberApp.transcriptionsWindow declares `Window("Transcriptions", id: TranscriptionsView.windowID)` ("transcriptions", default size 760 x 520, resizable), its content calls appState.pipeline.prepareTranscriptionsWindow() in onAppear, and the menu callback is `bringWindowToFront(id: TranscriptionsView.windowID)`. Verified by reading the code; the App has no test seam.
- R4. TranscriptionsViewTests.testTypingInTheSearchFieldWritesTheQuery (field located by A11yID.transcriptionsSearchField, setInput writes the binding) and testAQueryShowsOnlyMatchingRowsAndAnEmptyListSaysWhy (query "zoe" leaves only the entry with participant "Zoë", "budget" shows "No transcriptions match", an empty list shows "No transcriptions yet").
- R5. testOpenAndShowInFinderHandTheEntrysFileToTheirClosures (Open hands over the protocol URL, Show in Finder the transcript URL when there is no protocol, an entry with neither file has neither button) and testAMissingFileShowsTheMovedOrDeletedMessage (an Open whose closure returns false shows "The file was moved or deleted.", a later successful action clears it). The App's onOpen and onReveal call TranscriptionFileOpener.perform with appState.settings.effectiveOutputDir as scope root and NSWorkspace open or activateFileViewerSelecting; verified by reading the code, no NSWorkspace call in tests.
- R6. testAFailedRowShowsItsErrorRetryWhenAcceptedAndRemove (error text shown, Retry absent where canRetry is false and present where it is true, Retry and Remove hand their own row's id to onRetry and onRemove, a done row has neither even when canRetry answers true). The App wires Retry to PipelineController.retryJob(id:), which had no caller since task .2, and Remove to removeFailedJob.
- R2. testTheDetailLineShowsADashForEachMissingValue pins TranscriptionsView.detailLine for a pre-history record (dash placeholder for app, date and duration) and for a measured job ("Zoom", the formatted meeting start, "1:05").
- R8. TranscriptionsWindowPrivacyTests.testTheWindowIsOnNoDebugRPCWindowAllowlist (wrapped in #if !APPSTORE) checks TranscriptionsView.windowID against screenshotAllowedWindowIDs, uiTreeAllowedWindowIDs, uiPressAllowedWindowIDs and uiTypeAllowedWindowIDs, none of which this task edits. TranscriptionsViewTests.testNoIdentifierCarriesATitleParticipantOrPath renders a failed entry with title, participant and protocol path and asserts the window's identifiers are exactly the search field plus the four index-based row buttons.

A mutation run applied 7 source mutations one at a time (Open taking the transcript, the missing-file notice never set, failure actions on any finished row, the query ignored, an empty placeholder instead of the dash, the window id set to "settings", the menu item calling Settings); each turned its intended test red and the sources were restored byte-identical (/tmp/gh13/t4-mutate.py, /private/tmp/gh13/t4-mut-1.log to t4-mut-7.log).

Gates. Baseline before the edit was green (92 tests of the spec's Quick command filter, /private/tmp/gh13/t4-baseline.log). Lint with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 returned rc 0 (0 of 711 files need formatting, 0 violations, /private/tmp/gh13/t4-lint4.log). CI parity measured locally with Xcode 27.0: a clean xcodebuild build-for-testing succeeded under the 300 ms type-check gate, and swiftlint analyze --strict over its log found 0 violations (/private/tmp/gh13/t4-analyze-lint3.log), so the unused_declaration on PipelineController.retryJob(id:) is gone. ./scripts/pre-push.sh --with-appstore returned rc 0 (/tmp/gh13/t4-prepush.out). The focused filter under -DAPPSTORE ran 87 tests with rc 0 and the privacy test compiled out (/private/tmp/gh13/t4-appstore.log). The full suite ran once at 5f0abe42 (3786 tests, /private/tmp/gh13/t4-full.log); its failures are only the known environmental ones under the scratch home (LiveTranscriptionE2ETests, ModelPreloadTests.testPreloadParakeet, ParakeetE2ETests, WhisperKitLocalSnapshotTests.testProductionLocatesARealFetchedModel).

Changed user route (feature map): menu bar, a new item "All Transcriptions..." after the job lines (Cmd-T while the menu is open) opens the Transcriptions window; its search field, Open, Show in Finder, Retry and Remove are the window's controls.

Decisions:
- Declined the P2 finding from the correctness and integration draws that TranscriptionsFileNotice (an @Observable object holding the missing-file flag in @State) is test-only machinery and should be a plain @State Bool. The project's CLAUDE.md, GUI Testing rung 2, prescribes holding state worth asserting in one @Observable object (SpeakerNamingRowState), and acceptance criterion R5 names the moved-or-deleted message; with a Bool the message could not be asserted by any test. Both draws voted SHIP with the finding.
- The notice object is created in TranscriptionsView.init through State(initialValue:), as SpeakerNamingView does. As the property's default it failed the missing-file test (measured), because SwiftUI's State has a lazy `init(wrappedValue thunk: @autoclosure ...) where Value: AnyObject & Observable` (MacOSX27.0 SDK SwiftUICore interface) that hands an uninstalled view a new object on every read.
- TranscriptionsView.windowID is `nonisolated static let`, like the RPC allowlists, so the non-isolated privacy test reads it without an actor-isolation warning.
- Open and Show in Finder appear on any entry with a protocol or transcript, as the task says, so a job waiting for speaker names with a draft transcript offers them too; the menu still offers Open on finished lines only.
- The item sits directly after the job lines and before the divider that opens the protocol actions, so with no job lines it follows "Process Audio/Video Files...".
- `transcriptionsQuery` on the App carries a `swiftlint:disable:next unused_declaration` with its reason, since Xcode 27 swiftlint analyze does not see a reference through `$transcriptionsQuery`; SpeakersSettingsView.experimentalTuningExpanded is the precedent.

Follow-ups and notes:
- Look and feel of the window, the menu item and Cmd-T in the shipped app are not verified here; they are the owner's manual check at the spec's end, together with the shortened menu from task .3.
- The search query persists while the window is closed (App-level @State, as the task specified) and resets on app restart.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 5f0abe42f72cafc3cab51233cd4d8c5fd7b5e2fc
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh13-home swift test --parallel --filter 'TerminalJobRecordTests|TerminalJobStoreTests|TranscriptionListTests|PipelineControllerTranscriptionsTests|MenuBarJobMenuTests|MenuBarViewTests|TranscriptionsViewTests|TranscriptionsWindowPrivacyTests' (101 tests, rc 0 at 5f0abe42), same focused filter minus the two store suites with -Xswiftc -DAPPSTORE (87 tests, rc 0, privacy test compiled out), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (rc 0, 0 violations), xcodebuild build-for-testing (clean, 300 ms type-check gate) + swiftlint analyze --strict (rc 0, 0 violations), ./scripts/pre-push.sh --with-appstore (rc 0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh13-home swift test --parallel (3786 tests; only the known environmental model-download failures)
- PRs: