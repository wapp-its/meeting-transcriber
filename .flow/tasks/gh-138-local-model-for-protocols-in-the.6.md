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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
