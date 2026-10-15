---
satisfies: [R1]
---
# gh-138-local-model-for-protocols-in-the.6 Settings: Local model rows and Check Model

## Description
The accepted mockup's screens 1 and 2 in Settings → Output: provider entry, model-folder row with Choose…, status line and Check Model, below the provider picker in gh-2's reshaped Output tab.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift`, `app/MeetingTranscriber/Sources/Settings/LocalModelSettingsView.swift` (new), `app/MeetingTranscriber/Sources/LocalModel/LocalModelCheck.swift` (new), `app/MeetingTranscriber/Sources/A11yID.swift`, tests
**Touches:** [app/MeetingTranscriber/Sources/Settings/**, app/MeetingTranscriber/Sources/LocalModel/LocalModelCheck.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/LocalModelSettingsTests.swift]

### Approach
- Replace task 3's placeholder `.localModel` case in `providerConfigView` (`OutputSettingsView.swift:114-157`, gh-2 version) rendering a `LocalModelSettingsView`, like `CommandProviderSettingsView` does for Codex.
- Rows and copy exactly as the mockup: "Model folder" with the display path or "Not set" and Choose… (folder panel, stores the bookmark through task 3's setting); caption "A model folder from Hugging Face in MLX format. Tested: mlx-community/Qwen3.8-27B-4bit (16 GB)."; status line (ready with name · quantisation · size, or what is missing); Check Model button, disabled with no folder; the two notes about running on this Mac and waiting for recordings.
- `LocalModelCheck` runs the bundled helper's `check` mode; a result is shown only while it belongs to the folder currently chosen (a check started for folder A that ends after folder B was picked is dropped).
- `A11yID` constants for the folder button, the Check Model button and the status line; one ViewInspector wiring test per control per the repo's GUI testing rule.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift` (gh-2 version) — provider section and templates section
- `app/MeetingTranscriber/Sources/Settings/CommandProviderSettingsView.swift` — per-provider subview pattern
- `app/MeetingTranscriber/Sources/A11yID.swift:100-115`

**Optional:**
- `app/MeetingTranscriber/Tests/CommandProviderSettingsTests.swift` — settings wiring tests
## Acceptance
- [ ] ViewInspector: picking the provider shows the rows; Choose… and Check Model are wired; Check Model is disabled with no folder.
- [ ] Check results: ready, each missing-file case, unsupported model type; a superseded check never shows its result.
- [ ] The App Store variant's Output tab is unchanged.
## Done summary
Choosing "Local model (on this Mac)" in Settings, Output now shows the mockup's rows: the model folder with Choose..., a status line with Check Model, and the notes about running on this Mac and waiting for recordings. Check Model runs the bundled helper's `check` mode, which never loads weights, and the status line names the model, quantisation and size ("Qwen3.8-27B · 4-bit · 16.1 GB · ready") or what is missing or unsupported; without a folder it shows "No model chosen. Protocols are not written until one is set." and Check Model is disabled.

baseline: green via handoff (verified at 6e59cf6f by task .3; only .flow/ paths moved since), lint baseline rc=0
stage: impl-review - skipped(policy: parallel-wave - conductor owns the gate)
Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

### Acceptance criteria and their tests (all in `LocalModelSettingsTests`)

- Picking the provider shows the rows: `testPickingTheProviderShowsTheLocalModelRows` (provider picker driven to `.localModel`, then the three identifiers and "Model folder" are found; absent before).
- Choose... wired: `testChooseStoresThePickedFolderAndChecksIt` (injected folder picker; asserts the `AppSettings.localModelFolder` write-back and that a check started).
- Check Model wired: `testCheckModelChecksTheChosenFolderOneCheckAtATime` (tap starts a check; the button is disabled while it runs).
- Check Model disabled with no folder, R1 warning copy: `testCheckModelIsDisabledAndTheWarningShownWithNoFolder`.
- Check results through fake `#!/bin/sh` helpers: `testCheckRunsTheHelperOnTheFolderAndReadsItsVerdict` (ready, missing tokenizer.json, unsupported model type, folder itself missing, unreadable report, exit 1; also asserts the argument vector `check <folder>` with a folder path holding spaces and `$`).
- Status line for ready, each missing-file case (config.json, tokenizer.json, tokenizer_config.json, chat_template.jinja, model.safetensors, an indexed shard, several at once) and the unsupported model type: `testStatusLineNamesWhatTheCheckFound`.
- A superseded check never shows its result: `testACheckThatEndsAfterAnotherFolderWasChosenNeverShowsItsResult`. With both guards removed by mutation it failed, showing folder A's ready verdict while folder B was chosen.
- App Store Output tab unchanged: everything new is `#if !APPSTORE`; `swift build -Xswiftc -DAPPSTORE` rc=0 and `swift test -Xswiftc -DAPPSTORE --filter 'OutputSettings|CommandProviderSettings|LocalModel'` rc=0 (13 tests).
- Also: no helper or no folder starts nothing (`testCheckThatCannotRunStartsNoHelper`), a hanging helper is stopped at the timeout (`testCheckThatDoesNotAnswerInTimeIsStopped`), the notes follow the folder state (`testNotesFollowWhetherAFolderIsChosen`), and the rows check an unchecked folder when they appear (`testStatusLineChecksAnUncheckedFolderWhenItAppears`).

### Measured against the real helper

The helper built with `swift build -c release` in `tools/local-llm-helper` (rc=0). A temporary, uncommitted probe test ran `LocalModelCheck` with that binary on copies of a folder with the real tokenizer and placeholder shards. Status lines: `ready · 4-bit · 0.0 GB · ready` (folder named "ready", 72 bytes of shards), `Not a usable model. Missing: tokenizer.json.`, `... Missing: chat_template.jinja.`, `... Missing: model-00002-of-00003.safetensors.`, `... Model type llama9 is not supported.`, and `Model folder not found. Choose it again.` for a path with nothing at it. The Settings window itself was not driven (the app must not be launched here).

### Decisions

1. Rule 6. A check may take 30 s (`LocalModelCheck.timeout`), then `CLIProcessRunner` sends SIGTERM and SIGKILL 1 s later. A check reads a few small files; 30 s covers a cold or network volume.
2. Rule 6. A check in flight shows a small spinner and "Checking the model folder..." and disables Check Model; Choose... stays enabled and supersedes it. Pinned by `testCheckModelChecksTheChosenFolderOneCheckAtATime`.
3. Rule 6. `A11yID.localModelChooseFolderButton`, `localModelCheckButton`, `localModelStatus`. None is on the `/ui/press` allowlist (Choose... opens a panel).
4. Rule 6. The check reuses `CLIProcessRunner` (fixed argument vector, no shell, stdout capped at 1 MB, stdin on /dev/null, the per-user temporary directory as working directory). `LocalModelHelperRunner` is built around `run` mode (request file, progress lines, deadlines). `CLIProcessRunner` does not react to task cancellation, so a superseded check runs to its end (at most 30 s) and its result is dropped.
5. Rule 6. A result belongs to the whole `LocalModelFolderSelection` (path and bookmark) it ran on. A generation counter drops a late result, and the status line also shows a result only while its folder is the chosen one.
6. Rule 6. A bookmark that no longer resolves, a path with no directory, and a helper report of the folder itself as missing all read "Model folder not found. Choose it again.", the same folders the generator treats as no model. No helper starts for the first two.
7. Rule 4. The rows check the folder when the status line appears and nothing has checked it yet, and right after Choose..., so the line matches mockup screen 1 on opening. Switch: `LocalModelSettingsModel.checkIfNeeded` (the status line's `onAppear`) and the `startCheck()` call in `chooseFolder()`. Pinning tests: `testStatusLineChecksAnUncheckedFolderWhenItAppears`, `testChooseStoresThePickedFolderAndChecksIt`.
8. Rule 4. Status copy the mockup does not give: "Not a usable model." followed by "Missing: a, b." / "Unreadable: ..." / "Invalid: ..." / "Model type X is not supported." / "The folder cannot be read."; "Model folder not found. Choose it again."; "Cannot check: ..." for a missing helper, a failed start, the timeout, an exit status or an unreadable answer; "Not checked yet."; "Checking the model folder...". Switch: `LocalModelStatus.text`. Pinning test: `testStatusLineNamesWhatTheCheckFound`.
9. Rule 4. The ready line drops a trailing "-<bits>bit" from the folder name and gives the size in decimal GB with one decimal, as the mockup shows. Switch: `LocalModelStatus.readyText` / `displayName` / `gigabytes`. Pinning test: `testStatusLineNamesWhatTheCheckFound`.
10. Rule 4. The two notes show whenever a folder is chosen, whatever the check found; "Transcripts are still saved. Download the model folder, then choose it here." shows only without a folder (screens 1 and 2). Switch: the `Group` in `LocalModelSettingsView.body`. Pinning test: `testNotesFollowWhetherAFolderIsChosen`.
11. Rule 4. The tested model in the caption links to its Hugging Face page, as on mockup screen 2. Switch: `LocalModelSettingsView.folderCaption`. No pinning test (SwiftUI renders the Markdown link; framework behaviour is not tested here).
12. Rule 4. The folder panel's message is "Choose the folder of an MLX model"; the status icons carry the accessibility labels "Ready" and "Warning" as on the mockup. Switch: `LocalModelSettingsModel.showFolderPanel` and `statusLine`. No pinning test (the panel is manual-QA-only).

### Touches extended

None.

### Feature route changed

Settings, Output, LLM Provider "Local model (on this Mac)" now shows Model folder with Choose..., the status line with Check Model, and two notes (it was empty after task .3).

### Follow-ups

- The brief described `AppSettings.setLocalModelFolder(_:)` as taking nil to clear; it takes a URL. The rows offer no way to clear the folder (the mockup has none).
- A tiny folder reads "0.0 GB" on the ready line; only placeholder fixtures are that small.

### Gates at 28ea6ab1

- `swift build` rc=0, `swift build -Xswiftc -DAPPSTORE` rc=0.
- `CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'OutputSettings|LocalModel|CommandProviderSettings|SettingsInteraction|ViewInspectorIdentifier'` rc=0, 80 tests.
- App Store tests as above, rc=0.
- `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 (zip checksums verified): rc=0, 0 violations.
- `xcodebuild ... build-for-testing` rc=0, then `swiftlint analyze --strict` rc=0, 0 violations (run at b4314d64; the later commit only adds one test).


stage: impl-review - ran [21:46:29Z..21:50:06Z] (model: codex gpt-6-astra xhigh; three draws correctness, contracts, integration, all SHIP, no findings) - SHIP
stage: wave-join - ran (fast-forward 28ea6ab1 onto the spec branch; evidence SHAs unchanged)
stage: conductor-verify - ran at 28ea6ab1 (lane .6, same tree as the spec branch): swift build rc=0, swift build -Xswiftc -DAPPSTORE rc=0, focused tests rc=0 (555 cases), App Store test variant rc=0 (2 cases)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: b4314d643b4f3d3cafca717904a45582ac1c8f49, 28ea6ab1ea956cbf2a40ea7116485a64f5f91ce4
- Tests: cd app/MeetingTranscriber && swift build (rc=0), cd app/MeetingTranscriber && swift build -Xswiftc -DAPPSTORE (rc=0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'OutputSettings|LocalModel|CommandProviderSettings|SettingsInteraction|ViewInspectorIdentifier' (rc=0, 80 tests, at 28ea6ab1), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test -Xswiftc -DAPPSTORE --filter 'OutputSettings|CommandProviderSettings|LocalModel' (rc=0, 13 tests), PATH=/tmp/mt-flow/lint-tools:$PATH ./scripts/lint.sh (pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1, rc=0, 0 violations), xcodebuild -scheme MeetingTranscriber build-for-testing (rc=0) + swiftlint analyze --strict (rc=0, 0 violations), real helper (tools/local-llm-helper release build) check mode through LocalModelCheck on 6 probe folders (temporary uncommitted probe test): ready, missing tokenizer.json, missing chat_template.jinja, missing shard, unsupported model type, folder gone - each status line as expected, conductor verify at 28ea6ab1: swift build rc=0; swift build -Xswiftc -DAPPSTORE rc=0; focused tests rc=0, 555 cases; App Store test variant --filter 'LocalModel|CommandProviderSettings' rc=0, 2 cases
- PRs: