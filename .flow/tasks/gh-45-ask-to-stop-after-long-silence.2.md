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
Settings > General now has a "Long Silence" section where a user switches the stop question on or off (default on) and picks after how many minutes without speech it is asked (1 to 60, default 5); both choices are stored in UserDefaults and survive a relaunch. Nothing reads them yet: `AppSettings.silencePromptAfter` (minutes x 60, or nil while switched off) is the one value task .3 wires into the watch loop.

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

stage: impl-review - skipped(policy: parallel-wave - conductor owns the gate)

baseline: green via handoff (conductor at 77dc12cc: lint rc=0, focused tests rc=0, 219 tests). Lint was taken from that same-SHA run and not re-run before the first edit; it ran green after the change.

What changed (commit e4538127, base 77dc12cc):
- `AppSettings.silencePromptEnabled` (key `silencePromptEnabled`, default true) and `AppSettings.silencePromptMinutes` (key `silencePromptMinutes`, default 5), clamped to 1...60 in `didSet` by conditional reassignment and again in `init` when loaded, following `asymmetricSilenceWarningSeconds`.
- `AppSettings.silencePromptAfter: TimeInterval?` in `AppSettings+Computed.swift`.
- `SilencePromptSection` (private struct in `GeneralSettingsView.swift`, placed right after `Section("Detection")`): a `HelpfulToggle` "Ask to stop after a long silence" with `SettingsHelp.silencePrompt`, then an "Ask after" row with an "N min" label and a `Stepper` over 1...60; the row is `.disabled` while the switch is off. No `.recordOnlyDisabled`.
- `A11yID.silencePromptToggle`, `A11yID.silencePromptMinutesStepper`.

Tests (R6):
- `AppSettingsSilencePromptTests`: defaults on / 5 / 300 s; both values survive a fresh `AppSettings` on the same suite; 0 -> 1 and 61 -> 60 on write (value and stored key) and on load of a stored out-of-range value; threshold nil when switched off.
- `GeneralSettingsSilencePromptTests`: tapping the switch writes `silencePromptEnabled == false` and the stored key; incrementing the stepper writes `silencePromptMinutes == 6`, and the stepper reads disabled once the switch is off.
- Red first: before the implementation both files failed to compile on the missing members (`/tmp/gh45-tick/t2-tests-red.log`). The disabled assertion was proven falsifiable by removing `.disabled(...)`: the test failed with its message, then the modifier was restored (`/tmp/gh45-tick/t2-falsify.log`).

Gates (on the committed tree):
- Focused tests `swift test --parallel --filter "SilencePrompt|GeneralSettings|AppSettings|SettingsView"`: rc=0, 199 tests, all 7 new ones ran (`/tmp/gh45-tick/t2-tests-verify.log`).
- `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1: rc=0, 0/767 files need formatting, 0 violations.
- `swift build`: rc=0, `GeneralSettingsView.swift` recompiled with no long-function-body diagnostic.
- CI-parity `swiftlint analyze --strict` after a clean `xcodebuild build-for-testing`: rc=2 from 2 `unused_declaration` hits in `RecordingProvider.swift:144,146` (the non-throwing extension defaults of `storePendingCut` / `recordPendingCutResolution`, from gh-60, already on the base). No hit in the 7 changed files, all of which were analyzed. Left untouched (outside Touches); note in the run's flow-notes dir.

Decisions:
1. Rule 1 (task Approach): the section sits right after Detection, which also keeps the document-order stepper tests in `SettingsInteractionTests` (poll interval = first, grace = second) meaning what they say.
2. Rule 1 (R6 "disabled while the switch is off"): the stepper wiring test also asserts the disabled state, so that clause of R6 has a test.
3. Rule 4: `.disabled` covers the whole "Ask after" row (label, value, stepper), the way the echo-dedup switch disables its composite row. Switch point `GeneralSettingsView.swift:SilencePromptSection`; test `GeneralSettingsSilencePromptTests.testStepperWritesBackAndIsDisabledWhileSwitchedOff`.
4. Rule 6: the stepper carries the hidden label "Ask after" and the visible "Ask after" text is hidden from accessibility, so VoiceOver names the control once (as `HelpfulToggle` does). No automated test; manual QA.
5. Rule 6: stepper step 1 (the task names the range only); the value label is "N min" with monospaced digits.
6. Rule 6: the stored properties sit after `asymmetricSilenceWarningSeconds` in the Recording group of `AppSettings`, next to the other silence setting.
7. Rule 6: tests and implementation are one commit; a commit with tests that do not compile would break the build at that point. The red run is kept in the log above.
8. Rule 1 (working rules: problems the change does not cause are reported, not fixed): the two pre-existing analyze hits stay as they are.

Follow-ups: none from this task. The `/state` settings snapshot is not extended (spec Boundaries).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 88216a3b668ec415fae575ff2ba943c6b4ddd21d
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/mt-gh45-home-t2 swift test --parallel --filter "SilencePrompt|GeneralSettings|AppSettings|SettingsView" > /tmp/gh45-tick/t2-tests-verify.log 2>&1 (rc=0, 199 tests, 7 new), PATH="/tmp/gh45-tick/lint-tools/bin:$PATH" ./scripts/lint.sh (rc=0, 0/767 files need formatting, 0 violations), cd app/MeetingTranscriber && swift build -v > /tmp/gh45-tick/t2-build.log 2>&1 (rc=0, GeneralSettingsView.swift recompiled, no long-function-body diagnostic), bash /tmp/gh45-tick/t2-analyze.sh: clean xcodebuild build-for-testing + swiftlint analyze --strict (rc=2: 2 pre-existing unused_declaration hits in RecordingProvider.swift:144,146, untouched by this task; none in the 7 changed files)
- PRs: