---
satisfies: [R1]
---
# gh-99-show-recording-prompts-in-a-window.3 Settings switch for prompts below the menu bar icon

## Description
The stored setting and its switch with help text in Settings → General (R1, D9, A9, A10). The window that reads the setting comes in .4; this task has no dependency and can run beside .1 and .2.

**Size:** S
**Files:** `app/MeetingTranscriber/Sources/AppSettings.swift`, `Sources/Settings/GeneralSettingsView.swift`, `Sources/A11yID.swift`, `Tests/GeneralSettingsPromptWindowTests.swift` (new), `Tests/AppSettingsTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/AppSettings.swift, app/MeetingTranscriber/Sources/Settings/GeneralSettingsView.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/GeneralSettingsPromptWindowTests.swift, app/MeetingTranscriber/Tests/AppSettingsTests.swift]

All paths below are relative to `app/MeetingTranscriber/`.

### Approach
1. `AppSettings`: one stored Boolean for the setting, default false, persisted as `autoWatch` is (`Sources/AppSettings.swift:319-321`, loaded at `:1078` through `defaults.bool(forKey:default:)` from `Sources/UserDefaults+Bool.swift`), so a missing or unreadable value reads as off. Not mirrored into `/state` (`Sources/AppSettings+RPC.swift` stays unchanged).
2. A private section struct like `SilencePromptSection` (`Sources/Settings/GeneralSettingsView.swift:359-372`) holding `Section("Prompts")`, placed directly after the "Record Without Asking" group (A9). `body` already carries a `closure_body_length` exception, so it gains only the one line that places the section.
3. In the section: a plain `Toggle("Show prompts below the menu bar icon", …)` with an A11yID, and below it the help text word for word as R1 gives it, as a caption `Text` like the one at `:62-68`. Not `HelpfulToggle`: its help sits behind a badge (`Sources/Settings/HelpBadge.swift:68-86`), while the accepted board shows the text under the switch. Nothing else goes in the group (A10).
4. A11yIDs for the toggle and the help text in `Sources/A11yID.swift`.

### Investigation targets
**Required** (read before coding):
- `Sources/Settings/GeneralSettingsView.swift:30-130, 355-380` — sections, caption text, section struct
- `Sources/AppSettings.swift:315-325, 1070-1085` — a stored Boolean and its load
- `Tests/GeneralSettingsSilencePromptTests.swift` — isolated suite, find by A11yID, tap, assert property and stored key

**Optional** (reference as needed):
- `Tests/AppSettingsTests.swift:30-60` — default and persistence tests
- `docs/architecture/gui-testing.md` — one ViewInspector wiring test per control

## Acceptance
- [ ] The switch is found by its A11yID in General; a tap writes the setting back and a fresh `AppSettings` on the same suite reads it; a fresh `AppSettings` on an empty suite reads off.
- [ ] A test compares the help text with R1's text in full, and the group holds only the switch and the help text.
- [ ] The switch test fails when the toggle's binding is removed.
- [ ] Quick commands green; `./scripts/lint.sh` clean with the pinned tools.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
