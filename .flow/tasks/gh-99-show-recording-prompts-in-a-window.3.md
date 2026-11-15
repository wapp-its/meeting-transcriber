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
Settings → General now has a "Prompts" group, directly after "Record Without Asking", holding the switch "Show prompts below the menu bar icon" and R1's help text as a caption under it. The switch is backed by the stored flag `AppSettings.promptWindowEnabled` (key `promptWindowEnabled`), which is off by default and reads as off when the stored value is missing or unreadable. Nothing reads the flag yet: task .4 builds the window that does.



Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

### Acceptance

- AC1, switch found by A11yID, tap writes back, relaunch reads it: `GeneralSettingsPromptWindowTests.testSwitchWritesBackAndSurvivesARelaunch`. Empty suite reads off, and so do unreadable stored values ("on", `Data`): `AppSettingsTests.testPromptWindowReadsOffWhenItsStoredValueIsMissingOrUnreadable` (R1's error case).
- AC2, the help text compared in full with R1's text, and the group holds only the switch and its help text in that order: `GeneralSettingsPromptWindowTests.testGroupHoldsOnlyTheSwitchAndItsHelpTextAfterRecordWithoutAsking`. The same test pins A9 (the group comes right after "Record Without Asking").
- AC3, measured: with the binding replaced by `.constant(false)`, the switch test fails at both write-back assertions (lines 30 and 31). With the load default flipped to true, the default test fails for the missing value and for both unreadable values. Both mutations were reverted before the commit.
- AC4, measured: the Quick command passes (exit 0, 205 tests, 0 failures; the baseline was 202 at e18f56c0). `./scripts/lint.sh` with the pinned tools passes (exit 0).

### Verification

- baseline: green. The Quick command passed at e18f56c0 (202 tests, exit 0) and so did lint (exit 0).
- The Quick command ran with `-j 6` in both places, otherwise as written: `cd app/MeetingTranscriber && mkdir -p .build/test-home && swift build --build-tests -j 6 && CFFIXED_USER_HOME="$PWD/.build/test-home" swift test -j 6 --filter '<the spec filter>'`.
- Callers of `GeneralSettingsView` outside the filter all passed (exit 0, 192 tests): `LoginItemTests`, `MicInputDetectorSafariTests`, `MicInputDetectorSafariAppStoreTests`, `SettingsInteractionTests`, `SettingsViewTests`, `WatchSlackTests` and `AppSettingsUntypedDefaultsTests`.
- not run: the App Store build variant. The change contains no `#if APPSTORE`, and the conductor's full gate covers both variants.
- not run: a check in the running app. The installed app is not replaced during a build, and the switch has no visible effect until task .4.

### Choices

- Name of the property and stored key, `promptWindowEnabled`: rule (6). It matches `silencePromptEnabled` and the `PromptWindow*` names the spec gives its tests.
- A11yIDs `promptWindowToggle` and `promptWindowHelp`, both left off the `/ui/press` allowlist: rule (6), plus the A11yID guide's "add on demand" (no live driver presses the switch yet).
- Help text as a caption `Text` under the switch, not `HelpfulToggle`: rule (1), from task approach step 3 and D9.
- Group placed after "Record Without Asking": rule (1), A9. The group test pins the position.
- Flag left out of `/state` (`AppSettings+RPC.swift` unchanged): rule (1), from task approach step 1.
- No separate test-first commit: rule (1), CLAUDE.md Cross-Cutting Rules ("for something new, check that at the line that wires it into production"). Instead the binding mutation and the default mutation under AC3 were run.

### For task .4

- Read `settings.promptWindowEnabled` when the app renders. `GeneralSettingsView` and `AppSettings` are already updated, so .4 does not edit them.
- Follow-ups: none.

Integrated verify on the spec branch: the spec's Quick command with -j 6 at 2ff1b05e (task commit 35ecae73 cherry-picked onto the spec branch), exit 0, 205 tests, 0 failures

stage: impl-review - ran [2026-11-15T16:40:17Z..2026-11-15T16:46:29Z] SHIP, three draws (correctness, contracts, integration), no findings (model: gpt-6.1-sol at xhigh)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 2ff1b05ebaf153af6cf45caa313258048802bb4f
- Tests: cd app/MeetingTranscriber && mkdir -p .build/test-home && swift build --build-tests -j 6 && CFFIXED_USER_HOME="$PWD/.build/test-home" swift test -j 6 --filter 'PromptWindow|PromptPanel|MenuBarIconFrame|MeetingEndQuestion|WatchLoopMeetingEnd|NotificationManagerMeetingEndTests|NotificationManagerSchedulingTests|ConsentPromptCoordinatorTests|WatchLoopAskBeforeRecordingTests|WatchLoopBrowserConsentTests|AppStateConsentPromptTests|NamingWindowPolicyTests|GeneralSettings|AppSettingsTests|MenuBarIconCountdownTests' (exit 0, 205 tests, 0 failures; baseline 202), cd app/MeetingTranscriber && CFFIXED_USER_HOME="$PWD/.build/test-home" swift test -j 6 --skip-build --filter 'LoginItemTests|MicInputDetectorSafariTests|MicInputDetectorSafariAppStoreTests|SettingsInteractionTests|SettingsViewTests|WatchSlackTests|AppSettingsUntypedDefaultsTests' (exit 0, 192 tests, 0 failures), PATH=<pinned lint bin>:$PATH ./scripts/lint.sh (exit 0; SwiftFormat 0/1296 files need formatting, swiftlint --strict clean), integrated verify: the spec's Quick command with -j 6 at 2ff1b05e (task commit 35ecae73 cherry-picked onto the spec branch), exit 0, 205 tests, 0 failures
- PRs: