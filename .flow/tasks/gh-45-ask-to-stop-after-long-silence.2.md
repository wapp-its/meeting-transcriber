---
satisfies: [R6]
---
# gh-45-ask-to-stop-after-long-silence.2 Long Silence setting in Settings > General

Touches: app/MeetingTranscriber/Sources/AppSettings.swift, app/MeetingTranscriber/Sources/AppSettings+Computed.swift, app/MeetingTranscriber/Sources/Settings/GeneralSettingsView.swift, app/MeetingTranscriber/Sources/Settings/SettingsHelp.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/AppSettingsSilencePromptTests.swift, app/MeetingTranscriber/Tests/GeneralSettingsSilencePromptTests.swift

## Description
Adds the "Long Silence" setting (R6): the stored switch and minutes, the derived threshold the watch loop reads, and the Settings → General section that edits them. Independent of task .1 (disjoint files), so the two can run in parallel. Task .3 wires the threshold into the loop; until then the setting is stored but changes nothing.

**Size:** S
**Files:** `app/MeetingTranscriber/Sources/AppSettings.swift`, `app/MeetingTranscriber/Sources/AppSettings+Computed.swift`, `app/MeetingTranscriber/Sources/Settings/GeneralSettingsView.swift`, `app/MeetingTranscriber/Sources/Settings/SettingsHelp.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Tests/AppSettingsSilencePromptTests.swift` (new), `app/MeetingTranscriber/Tests/GeneralSettingsSilencePromptTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/AppSettings.swift, app/MeetingTranscriber/Sources/AppSettings+Computed.swift, app/MeetingTranscriber/Sources/Settings/GeneralSettingsView.swift, app/MeetingTranscriber/Sources/Settings/SettingsHelp.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/AppSettingsSilencePromptTests.swift, app/MeetingTranscriber/Tests/GeneralSettingsSilencePromptTests.swift]

### Approach
- `AppSettings.silencePromptEnabled: Bool`, key `silencePromptEnabled`, default true: follow `perChannelIndicatorEnabled` (`AppSettings.swift:240-246`, loaded in `init` at `:664` with `?? true`).
- `AppSettings.silencePromptMinutes: Int`, key `silencePromptMinutes`, default 5, clamped to 1…60 in `didSet` by conditional reassignment and clamped again when loaded: follow `asymmetricSilenceWarningSeconds` (`:282-295`, load at `:670`).
- `AppSettings.silencePromptAfter: TimeInterval?` in `AppSettings+Computed.swift`: `minutes × 60` when enabled, nil when switched off. This is the one value the loop reads.
- UI: a private `SilencePromptSection: View` in `GeneralSettingsView.swift`, used in the form right after `Section("Detection")` (`GeneralSettingsView.swift:99-122`); shape after `PerChannelIndicatorSection` (`Settings/AudioSettingsView.swift:102-141`). Section title "Long Silence". A `HelpfulToggle(title: "Ask to stop after a long silence", help: SettingsHelp.silencePrompt, isOn:)` with `.accessibilityIdentifier(A11yID.silencePromptToggle)`, then a row "Ask after" with a `Stepper` over `silencePromptMinutes` in `1 ... 60`, a "N min" label, `.accessibilityIdentifier(A11yID.silencePromptMinutesStepper)` on the stepper, and `.disabled(!settings.silencePromptEnabled)`.
- Help text in `SettingsHelp.swift` (pattern `:42-50`): "When nothing has been heard on any recorded track for this long, a notification asks whether to stop the recording. Stop now ends it, cuts off the silence at the end and processes it. Without an answer it keeps recording and asks again after the same time."
- No `.recordOnlyDisabled`: the question applies in record-only mode too.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/AppSettings.swift:240-295, 655-672` — stored settings with defaults and clamps
- `app/MeetingTranscriber/Sources/Settings/GeneralSettingsView.swift:30-125` — the form and the Detection section
- `app/MeetingTranscriber/Sources/Settings/AudioSettingsView.swift:102-141` — a section view with a `HelpfulToggle`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/GeneralSettingsWatchAtLaunchTests.swift:9-26` — one ViewInspector wiring test per control
- CLAUDE.md "GUI Testing" — the two-step `find(viewWithAccessibilityIdentifier:)` then `find(ViewType.Stepper.self)` for a stepper

### Key context
- The build treats any function body that takes over 300 ms to type-check as an error (`-warn-long-function-bodies=300` in `Package.swift`, spec gh-17). Keep the new controls in their own small view struct; do not inline them into `GeneralSettingsView.body`.
- `AppSettings.init` already carries `// swiftlint:disable:next function_body_length`; two more load lines fit under it.
- The `/state` settings snapshot (`AppSettings+RPC.swift`) is not extended here (spec Boundaries).

## Acceptance
- [ ] `AppSettingsSilencePromptTests` (isolated `UserDefaults` suite, removed in teardown via `DefaultsSuite.remove`): defaults are on, 5 and `silencePromptAfter == 300`; both values survive a fresh `AppSettings` on the same suite; 0 is clamped to 1 and 61 to 60, on write and on load of a stored out-of-range value; `silencePromptAfter` is nil when switched off.
- [ ] `GeneralSettingsSilencePromptTests`, one ViewInspector wiring test per control located by its `A11yID` constant: tapping the switch writes `silencePromptEnabled == false` and the stored key; incrementing the stepper writes `silencePromptMinutes == 6`.
- [ ] Focused run green: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch dir> swift test --parallel --filter "SilencePrompt|GeneralSettings|AppSettings|SettingsView" > <log file> 2>&1`, read from the log file.
- [ ] `swift build` shows no `-warn-long-function-bodies` diagnostic for `GeneralSettingsView`, and `./scripts/lint.sh` reports no violations with the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (`scripts/tool-versions.sh`).


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
