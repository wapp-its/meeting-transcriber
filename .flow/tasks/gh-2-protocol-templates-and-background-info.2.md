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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
