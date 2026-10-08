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
Settings → Output → LLM Provider now lists "Codex CLI" and "Custom Command" in the Homebrew build, each with its own panel. Codex CLI shows captions only (runs `codex exec` with the user's Codex login, model and effort from Codex's own configuration, started with `--ephemeral` so no session is saved). Custom Command shows a monospaced command editor (one argument per line, program first, run without a shell), a "Model" field ("Replaces {model}."), the placeholder and stdin/stdout captions, and the exact line "What the command does with the transcript is up to the command." Both panels live in the new `CommandProviderSettingsView.swift` (whole file `#if !APPSTORE`); `OutputSettingsView.providerConfigView` only swaps the two interim captions for them. `A11yID` gains `customCommandEditor`, `customCommandModelField` and `codexProviderNote`. `docs/architecture-macos.md` (overview diagram, Provider Selection, one paragraph on the shared CLI runner) and `README.md` (feature list, diagram node, Output settings row) list the two providers; `CLAUDE.md` and `AGENTS.md` are unchanged.

Tests (`CommandProviderSettingsViewTests`, 6): provider picker selection writes `.customCommand`; the editor writes `customCommandArguments` one per line (`"ollama\nrun\nqwen3:32b"` → three entries); the model field writes `customCommandModel` via `setInput`; Custom Command shows the responsibility line and no Codex note; Codex shows its note and neither command control; a hosted `NSTextView` typing test proves `--` and straight quotes reach the stored arguments unchanged (AppKit smart substitution would otherwise rewrite them). Each control is located by its `A11yID` constant.

Deviation from the task text: the command editor is a `CommandArgumentsEditor` (an AppKit text view wrapped for SwiftUI) rather than a plain `TextEditor`, so the one-argument-per-line test sets the editor's text on the actual view instead of `setInput`; the hosted typing test covers the real event path. Chosen because a plain `TextEditor` applies smart dashes and quotes, which would corrupt command arguments as typed.

Type-check budget (`-debug-time-function-bodies`, six builds each, logs `/private/tmp/mt-gh7-t3-tc-b*.log` before at c6b0ac3a and `/private/tmp/mt-gh7-t3-tc-a*.log` after): `OutputSettingsView.body` 68–138 ms before, 68–92 ms after; `providerConfigView` 8–16 ms before, 8–12 ms after. Neither grew beyond noise.

Gates, re-run this tick at 6193f573 (the implementing tick ran past its time limit after committing; this tick reclaimed the task): focused suite `CommandProviderSettingsViewTests|SettingsInteractionTests|OutputSettingsViewTests|SettingsViewTests` 100 tests, exit 0; `swift build -Xswiftc -DAPPSTORE` exit 0; `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1: 0 violations in 697 files.

Follow-ups (not filed here): the look and feel of the two panels is the owner's check; a real `codex exec` run and a real `ollama run` remain the owner's checks, as the spec says.

Review: round 1, one correctness draw (gpt-5.6-sol, effort xhigh), SHIP with no findings; the validator pass did not apply (no NEEDS_WORK). The implementing tick's abandoned fan-out reservation was replayed and refunded by this dispatch.

Tier: routing block -> opus at xhigh (implementation by the prior tick's worker, actual: claude-opus-5-5); verify, review and done by the conductor (claude-fable-5-1)

stage: impl-review - ran [2026-10-08T07:48:31Z..2026-10-08T07:53:11Z] (model: gpt-5.6-sol xhigh)
stage: plan-sync - skipped(config: planSync.enabled=false)
## Evidence
- Commits: 873ee0f5be3cab9c360fec6c4be99bea0fa0d830, 6193f5731aea2ee0ef7295a97760154a6a97d4df
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh7-home swift test --parallel --filter 'CommandProviderSettingsViewTests|SettingsInteractionTests|OutputSettingsViewTests|SettingsViewTests' (100 tests, exit 0 at 6193f573), cd app/MeetingTranscriber && swift build -Xswiftc -DAPPSTORE --scratch-path /private/tmp/mt-gh7-appstore-build (exit 0 at 6193f573), PATH=/private/tmp/gh4/tools:$PATH ./scripts/lint.sh with SwiftFormat 0.63.0 and SwiftLint 0.65.1 (0 violations in 697 files at 6193f573)
- PRs: