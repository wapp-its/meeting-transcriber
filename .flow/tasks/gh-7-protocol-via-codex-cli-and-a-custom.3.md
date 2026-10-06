---
satisfies: [R7]
---
# gh-7-protocol-via-codex-cli-and-a-custom.3 Settings controls for Codex CLI and Custom Command, provider docs

## Description
Show the two providers in Settings → Output and update the provider lists in the docs. The views live in their own small file so `OutputSettingsView`'s `body` does not grow toward the CI's 300 ms per-body type-check limit (issue #17).

**Size:** S
**Files:** `app/MeetingTranscriber/Sources/Settings/CommandProviderSettingsView.swift` (new), `app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Tests/CommandProviderSettingsViewTests.swift` (new), `docs/architecture-macos.md`, `README.md`
**Touches:** [app/MeetingTranscriber/Sources/Settings/CommandProviderSettingsView.swift, app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/CommandProviderSettingsViewTests.swift, docs/architecture-macos.md, README.md]

### Approach

- New file, whole file `#if !APPSTORE`: `CodexProviderSettingsView` (captions only: it runs `codex exec` with the user's Codex login; model and reasoning effort come from Codex's own configuration; Codex is started with `--ephemeral`, so it saves no session of the run) and `CustomCommandSettingsView` with `@Bindable var settings: AppSettings`: a `TextEditor` bound to `$settings.customCommandText` (monospaced, `minHeight` about four lines, pattern `TranscriptionSettingsView.swift:147-165`), a "Model" `TextField` bound to `$settings.customCommandModel` with the caption "Replaces {model}.", captions saying one argument per line with the program (a name or a full path) on the first line, run directly without a shell, and the placeholders with the stdin/stdout rule as in the spec's table, and the exact line "What the command does with the transcript is up to the command."
- `OutputSettingsView.providerConfigView` (`OutputSettingsView.swift:114-150`): replace the interim captions task .2 put in the `.codexCLI` and `.customCommand` cases with those views; nothing else in that file grows.
- `A11yID.swift`: `customCommandEditor`, `customCommandModelField`, `codexProviderNote` (attach the last to the Codex view's container so a test can find it).
- Docs: `docs/architecture-macos.md` overview diagram (`:75`) and "Provider Selection" (`:583-587`) list the two providers, plus one short paragraph near "Claude CLI Invocation" saying all CLI providers share one runner (private run folder, no shell, wall-clock timeout); `README.md` feature list (`:95`), the diagram node (`:58`) and the Output settings row (`:256`) mention Codex CLI and a custom command. Do not edit `CLAUDE.md` or `AGENTS.md` (fork rule).

### Investigation targets

**Required** (read before coding):
- `app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift:80-150` — provider picker and per-provider config
- `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift:147-165` — the `TextEditor` + identifier + caption pattern
- `app/MeetingTranscriber/Tests/SettingsInteractionTests.swift:60-71` — provider picker write-back test
- `app/MeetingTranscriber/Tests/TranscriptionSettingsVocabularyTests.swift:25-43` — find-by-identifier and `setInput` pattern

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/A11yID.swift:1-20` — identifier conventions
- `docs/architecture-macos.md:575-600`, `README.md:50-60` and `:250-260`

### Key context

- One ViewInspector wiring test per control (CLAUDE.md "GUI Testing"), found by its `A11yID` constant: `setInput` on the editor writes `customCommandArguments` (`"ollama\nrun\nqwen3:32b"` → three entries); `setInput` on the model field writes `customCommandModel`; selecting `.customCommand` in the "LLM Provider" picker writes the setting (locator as in `SettingsInteractionTests.swift:60-71`); with `.codexCLI` the `codexProviderNote` is present and the editor absent; `find(text:)` for the "up to the command" line is allowed because that sentence is the behaviour under test. If ViewInspector 0.10.3 cannot drive a `TextEditor`, assert the identifier's presence instead, rely on task .2's `customCommandText` round-trip test, and say so in the done summary.
- The bindings write into `AppSettings`, a reference type, so the write-back is assertable; no `@State` draft is needed.
- Type-check budget: compare `OutputSettingsView`'s body and `providerConfigView` before and after with `cd app/MeetingTranscriber && swift build -Xswiftc -Xfrontend -Xswiftc -debug-time-function-bodies > /private/tmp/mt-gh7-t3-typecheck.log 2>&1`; neither may grow beyond noise.
- Verification: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh7-home swift test --parallel --filter 'CommandProviderSettingsViewTests|SettingsInteractionTests|OutputSettingsViewTests|SettingsViewTests' > /private/tmp/mt-gh7-t3.log 2>&1` (read the log; never pipe a test run); `cd app/MeetingTranscriber && swift build -Xswiftc -DAPPSTORE --scratch-path /private/tmp/mt-gh7-appstore-build > /private/tmp/mt-gh7-t3-appstore.log 2>&1`; `./scripts/lint.sh` with the pinned tools from `scripts/tool-versions.sh`.
- Look and feel of the new controls is the owner's check, not a task.
## Acceptance
- [ ] Settings → Output → LLM Provider lists "Codex CLI" and "Custom Command" in the Homebrew build; selecting each shows its own controls and notes, including the exact line "What the command does with the transcript is up to the command." for Custom Command (R7).
- [ ] One ViewInspector wiring test per new control passes (editor, model field, provider picker selection), each locating its control by an `A11yID` constant.
- [ ] `OutputSettingsView`'s body and `providerConfigView` type-check times do not grow beyond noise (before/after figures in the done summary).
- [ ] `docs/architecture-macos.md` and `README.md` list the new providers; `CLAUDE.md` and `AGENTS.md` are unchanged.
- [ ] The App Store variant builds and `./scripts/lint.sh` passes with the pinned tools.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
