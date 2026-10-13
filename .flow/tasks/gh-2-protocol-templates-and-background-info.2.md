---
satisfies: [R1]
---
# gh-2-protocol-templates-and-background-info.2 Protocol templates section in Settings → Output

## Description
Replaces the single-prompt controls in Settings → Output with the "Protocol Templates" section from the spec ("Settings → Output"): default picker, per-template Edit and Delete, a name field with Create Template, Open Templates Folder and the help text. It is its own task because it only consumes task 1's store and setting, and touches no recording or pipeline code. Also updates the user docs that describe the old custom prompt.

**Size:** M
**Files:** new `app/MeetingTranscriber/Sources/Settings/ProtocolTemplatesSettingsView.swift` (view plus `@Observable ProtocolTemplatesModel`), `Sources/Settings/OutputSettingsView.swift`, `Sources/A11yID.swift`, `README.md`, `docs/architecture-macos.md`, new `Tests/ProtocolTemplatesSettingsTests.swift`, `Tests/SettingsViewTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/Settings/ProtocolTemplatesSettingsView.swift, app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift, app/MeetingTranscriber/Sources/A11yID.swift, README.md, docs/architecture-macos.md, app/MeetingTranscriber/Tests/ProtocolTemplatesSettingsTests.swift, app/MeetingTranscriber/Tests/SettingsViewTests.swift]

### Approach
- `ProtocolTemplatesModel` holds the store, the settings and an injectable `openFile: (URL) -> Void` (default `NSWorkspace.shared.open`); state: `names`, `newName`, `message` (validation or I/O error), `pendingDeletion: String?`. Operations: `reload()`, `defaultSelection` get/set (get = `store.effectiveDefault(settings.defaultProtocolTemplate)`, set writes the setting), `create()` (validate with `ProtocolTemplateName.validate`, create, clear the field, reload, open the file), `edit(name)`, `requestDelete(name)` / `confirmDelete()` (trash through the store; deleting the stored default resets the setting to `.builtIn`), `openFolder()` (create the folder if missing, then open it; it never writes task 1's migration marker, so a migration that failed earlier still runs at the next launch). Keep all state in the model so tests assert writes (pattern `SpeakerNamingRowState`, see CLAUDE.md "GUI Testing" on `@State`).
- View: a `Section("Protocol Templates")` placed inside the Protocol Generation section where `promptControls` sits today (`OutputSettingsView.swift:100`), so it inherits `.recordOnlyDisabled`. Rows via `ForEach(names.enumerated())` with identifiers by index: `A11yID.protocolTemplateEdit(i)`, `A11yID.protocolTemplateDelete(i)`; plus `protocolTemplateDefaultPicker`, `protocolTemplateNameField`, `protocolTemplateCreateButton`, `protocolTemplatesOpenFolderButton`. Delete confirmation via `.confirmationDialog` bound to `pendingDeletion`. Reload on `.onAppear` and on `NSApplication.didBecomeActiveNotification`.
- Remove `promptControls`, `refreshCustomPromptState`, `ensurePromptDirectory`, `openCustomPrompt`, `importCustomPrompt` and the `hasCustomPrompt`/`showResetPromptConfirmation` state from `OutputSettingsView` (`:42-43`, `:224-337`). `OutputSettingsView` gains `templateStore: ProtocolTemplateStore = .production` so `SettingsView` needs no change and tests inject a temp store.
- Template names never go into accessibility identifiers (`/ui/tree` publishes identifiers unredacted, see the comment on `A11yID.consentDeniedAppRemove`).
- Docs: `README.md:96` (feature line: templates folder, default, placeholders, background info) and `README.md:256` (Output row); `docs/architecture-macos.md:715` (Output row: templates section, model instead of `hasCustomPrompt`).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift:32-112,224-337` — section layout and the controls being replaced
- `app/MeetingTranscriber/Sources/SpeakerNamingRowState.swift` — `@Observable` state object pattern for assertable writes
- `app/MeetingTranscriber/Sources/A11yID.swift:19-60` — identifier conventions (index-addressed rows)

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/SettingsViewTests.swift:460-480` — tests of the removed buttons, to replace
- `app/MeetingTranscriber/Tests/TranscriptionSettingsCustomModelTests.swift:80-105` — `setInput` on a text field
- `app/MeetingTranscriber/Tests/OutputSettingsViewTests.swift` — Output view test setup

### Key context
- The analyze build enforces a 300 ms type-check budget per body (`-warn-long-function-bodies=300`); keep the new view split into small computed properties and out of `OutputSettingsView`'s body.
- A `Picker` whose selection matches no tag renders blank; the picker's selection is the effective default for that reason.
- The confirmation dialog and the default editor are manual-QA-only; the model's `confirmDelete` is what tests drive.
- Do not edit `CLAUDE.md` or `AGENTS.md`.
## Acceptance
- [ ] Model tests against a temp store and a throwaway `UserDefaults` suite: create with a valid name writes the built-in text, clears the field and calls `openFile`; an invalid or duplicate name sets `message` and creates nothing; delete moves the file through the injected trash and resets a deleted default to built-in; `defaultSelection` shows built-in for a missing file and writes the setting; `openFolder` creates a missing folder; `reload` picks up a file added on disk (R1).
- [ ] One ViewInspector wiring test per control, located by its `A11yID` constant: default picker, name field, Create Template, Edit and Delete of row 0, Open Templates Folder (R1).
- [ ] The Edit Prompt / Import Prompt / Reset to Default buttons and the custom-prompt label are gone, and their old tests are replaced (R1).
- [ ] `README.md` and `docs/architecture-macos.md` describe templates instead of the single custom prompt file.
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<scratch> swift test --parallel --filter "ProtocolTemplates|SettingsView|OutputSettings|SettingsInteraction" > /private/tmp/<scratch>/t2.log 2>&1` passes (read the log file).
- [ ] `./scripts/lint.sh` passes with the pinned tools, and `swift build -c release -Xswiftc -DAPPSTORE` compiles.
## Done summary
Settings → Output now has a "Protocol Templates" section in place of the Edit Prompt / Import Prompt / Reset to Default buttons, which edited a file nothing reads any more. It has a Default template picker (the built-in "Standard (built-in)" plus every template file), Edit and Delete on each template (Delete asks first, then moves the file to the Trash), a name field with Create Template (a refused name or a failed write shows its message under the field), Open Templates Folder, and the placeholder help text. Files added, renamed or removed in Finder show up when the app becomes active again. README.md and docs/architecture-macos.md now describe templates instead of the single custom prompt file.

stage: impl-review - ran [..2026-10-13T18:28:22Z] (codex gpt-5.6-sol at xhigh, 2 rounds: round 1 NEEDS_WORK with 1 finding, fixed in 98fbe2bb; round 2 SHIP with 0 findings; start time not recorded)
Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

Baseline: green before any edit (100 tests, the task's acceptance filter, rc=0).

Commits:
- 2a09a199 feat(app): new Sources/Settings/ProtocolTemplatesSettingsView.swift (the @Observable ProtocolTemplatesModel and the section view), six A11yID entries, OutputSettingsView without the old prompt controls and their helpers and state (plus the now-unused UniformTypeIdentifiers import) and with templateStore: ProtocolTemplateStore = .production, the new Tests/ProtocolTemplatesSettingsTests.swift, the four old prompt-button tests in SettingsViewTests replaced by one, and the docs.
- 98fbe2bb fix(app): fixes the review finding. Renaming the default Board.md to board.md in Finder blanked the picker and left a stale default after deleting "board". The picker selection now uses the folder's spelling, and delete decides from that selection, read before the file goes.

Acceptance evidence:
- Model tests (ProtocolTemplatesSettingsTests):
  - testCreateWritesTheBuiltInTextClearsTheFieldAndOpensTheFile.
  - testARefusedNameSetsTheMessageAndCreatesNothing (table: empty, too long, "/", leading dot, duplicate in a different case; checks the exact refusal text, an unchanged folder and that nothing opens).
  - testAFailedCreateShowsTheErrorAndLeavesTheFolderUnchanged (read-only folder).
  - testDeleteTrashesThroughTheInjectedTrashAndResetsADeletedDefault.
  - testAFailedDeleteShowsTheErrorAndKeepsTheTemplateAndTheDefault.
  - testDefaultSelectionShowsTheBuiltInForAMissingFileAndWritesTheSetting.
  - testOpenFolderCreatesAMissingFolderWithoutTheMigrationMarker.
  - testReloadPicksUpAFileAddedOnDisk.
  - testACaseOnlyRenameOfTheDefaultStaysSelectedAndDeletable (the review fix).
- Wiring tests, one per control, located by A11yID: testDefaultPickerWritesTheSetting, testNameFieldWritesTheModel, testCreateButtonCreatesTheTypedTemplate, testEditOfRowZeroOpensItsFile, testDeleteOfRowZeroAsksForConfirmation, testOpenFolderButtonOpensTheFolder.
- Old controls gone: SettingsViewTests.testOutputShowsProtocolTemplatesInsteadOfThePromptControls finds the four new identifiers and fails to find Edit Prompt, Import Prompt, Reset to Default, "Custom prompt active" and "Using default prompt".
- Mutation checks, each reverted afterwards, each turned its matching test red:
  - Removing the default reset on delete.
  - The picker reading the raw setting instead of the effective default.
  - Open Templates Folder no longer creating the folder.
  - Moving Edit's identifier to the wrong row.
  - Reverting the case-only-rename fix.

Gates on 98fbe2bb:
- Acceptance filter: 112 tests, rc=0.
- `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1: rc=0, 0 violations.
- `swift build -c release -Xswiftc -DAPPSTORE`: rc=0.
- `swift build -c release`: rc=0.
- CI's `swiftlint analyze --strict` (clean xcodebuild build-for-testing on 2a09a199): build succeeded, and no violation is in a file this task touched. It does report 2 older `unused_declaration` errors in Sources/RecordingProvider.swift:144 and :146; this branch does not change that file and its last change is already on wapp/main. The fix commit added one private helper, which the model uses.

DECIDED:
- The section is its own `Section("Protocol Templates")` directly below Protocol Generation, with its own `.recordOnlyDisabled`, instead of nested inside the Protocol Generation Section. A Section inside a Section of a grouped Form has no defined layout, and record-only mode dims it the same way either way.
- `confirmDelete(_ name:)` takes the confirmed row's name instead of reading `pendingDeletion`. The delete then does not depend on whether SwiftUI clears the dialog binding before or after it runs the button's action. `pendingDeletion` still drives the per-row dialog, and the Delete wiring test asserts it.
- The model takes an injectable `trashItem` next to `openFile`, so the acceptance's "delete moves the file through the injected trash" is testable without the real Trash.
- `onAppear` and the didBecomeActive reload sit on the Default template picker, not on the Section. The picker is always shown, and a modifier on a Form Section can apply once per row.
- One message slot shows a refused name, a failed create, a failed delete and a failed folder open, under the name field. Any later successful operation clears it.
- Picker selection = effective default spelled as the folder lists it: an exact match first, then a case-insensitive one. Reading it never rewrites the setting, so the spec's "restoring the file restores the default" still holds.
- In the tests, closures are passed through local lets: SwiftLint's trailing_closure fix would have rebound a `trashItem:` closure to `openFile`.
- Docs: README's feature line is now "Protocol templates", and its Output row names the template controls. docs/architecture-macos.md gets a row for the new Settings file, a short paragraph on where a job's prompt comes from (the template, captured at enqueue, read at generation, built-in fallback, migrated "Custom Prompt"), "Every template can also use …" in place of "Custom prompts can also use …", and updated Output rows in the Settings UI table and in the list of what each Settings view owns.

ASSUMED: Create Template stays enabled with an empty field and answers "Enter a name for the template." instead of being disabled · flip at: app/MeetingTranscriber/Sources/Settings/ProtocolTemplatesSettingsView.swift:ProtocolTemplatesSettingsView.createRow · test: ProtocolTemplatesSettingsTests.testARefusedNameSetsTheMessageAndCreatesNothing (the "   " case)
ASSUMED: copy not fixed by the spec: name field placeholder "New template name", row buttons "Edit" / "Delete", confirmation title "Move “<name>” to the Trash?" with the button "Move to Trash", the message in red caption under the field · flip at: app/MeetingTranscriber/Sources/Settings/ProtocolTemplatesSettingsView.swift:ProtocolTemplatesSettingsView.templateRows / createRow · test: ProtocolTemplatesSettingsTests wiring tests (they find controls by A11yID, so the copy can change; the confirmation dialog is manual-QA-only per the task)
ASSUMED: the built-in template appears only in the Default template picker as "Standard (built-in)", with no read-only row in the template list (the spec's design asks for "one row per file template") · flip at: app/MeetingTranscriber/Sources/Settings/ProtocolTemplatesSettingsView.swift:ProtocolTemplatesSettingsView.templateRows · test: ProtocolTemplatesSettingsTests.testEditOfRowZeroOpensItsFile (row 0 is the first file template)

BLOCKED: none.

Follow-ups (outside this task's Touches, not fixed):
1. CLAUDE.md:231 still says `ProtocolGenerator.loadPrompt()` loads `protocol_prompt.md`. That has been stale since task 1, and CLAUDE.md may not be edited in this fork without the owner.
2. The doc comment at Sources/DualTrackViability.swift:107 still says "a user's own `protocol_prompt.md` replaces the built-in one"; it is now a template.
3. docs/architecture-macos.md's file table has no row for task 1's Sources/ProtocolTemplates.swift.
4. `swiftlint analyze --strict` fails on two older no-op stubs in Sources/RecordingProvider.swift:144 and :146 (`storePendingCut`, `recordPendingCutResolution`). Since fork CI is off, a local analyze run before the PR will hit them.

Feature route changed: Settings → Output's custom-prompt buttons are replaced by the "Protocol Templates" section. There is no .flow/features map in this repo.
Owner checks (manual QA): how the section looks, the delete confirmation, Edit opening the default editor, and Open Templates Folder opening Finder.
Memory: captured the bug entry .flow/memory/bug/ui/case-only-finder-rename-blanked-a-2026-10-13.md from the NEEDS_WORK → SHIP cycle.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 2a09a199b6a2d67d74e55b705bc3981792e1cfb6, 98fbe2bba626d2f617e84e971a66b6dc26fce5c2
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh2-home swift test --parallel --filter "ProtocolTemplates|SettingsView|OutputSettings|SettingsInteraction" (112 tests, rc=0), PATH="/tmp/gh2-tick/lint-bin:$PATH" ./scripts/lint.sh (SwiftFormat 0.63.0, SwiftLint 0.65.1; rc=0, 0 violations), cd app/MeetingTranscriber && swift build -c release -Xswiftc -DAPPSTORE (rc=0), cd app/MeetingTranscriber && swift build -c release (rc=0), swiftlint analyze --strict over a clean xcodebuild build-for-testing log at 2a09a199 (build ok; 2 older unused_declaration errors in Sources/RecordingProvider.swift:144,146, none in this task's files)
- PRs: