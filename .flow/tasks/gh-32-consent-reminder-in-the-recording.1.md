---
satisfies: [R1, R2]
---
# gh-32-consent-reminder-in-the-recording.1 Implement Consent reminder in the recording prompt and Settings

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
Every "Record <app> meeting?" prompt now ends with "Everyone must agree to being recorded." (one shared prompt path covers native, mic-input and browser meetings), and Settings > General > Record Without Asking shows, under each app whose switch is on, a caption saying that without the prompt making sure everyone agrees is entirely up to the user (Art. 179bis StGB, Swiss Criminal Code); the caption disappears when the switch is turned off.

Tests: R1 is pinned by a new assertion in WatchLoopAskBeforeRecordingTests.testEveryAnswerForEveryKindOfApp (every kind of asking app, every answer); R2 by GeneralSettingsRecordWithoutAskingTests.testTheConsentNoteShowsOnlyWhileAnAppsSwitchIsOn (exact text, absent while off, appears on tap, disappears on tap off). Both were run red before the implementation and green after. Baseline: green (15 focused tests, lint 0 violations). Post-change: 135 focused tests across the General-settings, settings-view and watch-loop consent suites green, pinned lint 0 violations. An offscreen render of the General tab confirmed the caption sits directly under each switched-on app.

Decisions: the caption shows whenever the stored switch is on, also while the app itself is not watched (the switch still states the user's choice); the prompt sentence is the shortest form that fits a two-line notification body. Not verified: how the longer prompt body truncates in a real macOS banner (needs the installed app; not launched alongside the owner's running Dev app).

Tier: implementer opus at xhigh

stage: impl-review - ran [2026-10-05T12:39Z..2026-10-05T12:46Z] (codex gpt-5.6-sol xhigh, one correctness draw, SHIP, no findings)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 568946c4ac575250024bde5c3d9b129ab34a1646
- Tests: CFFIXED_USER_HOME=<scratch>/home-gh32 swift test --parallel --filter 'GeneralSettings|WatchLoopAskBeforeRecordingTests|WatchLoopBrowserConsentTests|SettingsInteractionTests|SettingsViewTests' (135 tests, rc 0), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (0 violations)
- PRs: