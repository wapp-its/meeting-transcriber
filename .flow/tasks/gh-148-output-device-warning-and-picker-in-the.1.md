---
satisfies: [R1, R2, R3, R4, R5, R6, R7, R8, R9]
---
# gh-148-output-device-warning-and-picker-in-the.1 Implement Output device warning and picker in the menu

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
Warns when a recording with an app track starts on, or moves onto, Teams' loopback output (UID `MSLoopbackDriverDevice_UID`): one time-sensitive notification and one unconditional log line per routing, plus the red app-half tint on the menu-bar icon while the routing holds. The menu gains an Output entry below Microphone that names the default output, lists the outputs Core Audio offers as a default, and switches the default output system-wide; a running recording follows through the existing output-change restart.

- One app-side observer (`OutputDeviceController`) serves the menu and the warning; the capture library is unchanged (spec A6).
- Device filter measured on this Mac: the Teams device and private aggregates both report CanBeDefaultDevice = 0, so one filter hides both; the current default is always listed (disabled when not offered).
- The app's real `OutputDevices` reader ran against this Mac's Core Audio: three outputs listed, default read, an unknown UID refused with `kAudioHardwareBadDeviceError`, a set of the current default onto itself returned noErr.
- Attach/detach of a recording's observers moved to `WatchingController+RecordingObservers.swift` to stay within the lint limits.

stage: impl-review - ran [61ea6384..d4273838] (model: gpt-6-astra, three draws, SHIP, no findings)

Not verified here: the warning in a real Teams call that switches the output (needs the owner's Teams account).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 575f3da88bb5c218f7611ef9e9501bb77f07a2db, d4273838339cc8bbfe29044286506caa19ad5d2a
- Tests: swift test --parallel --filter 'OutputRoutingWarningTests|OutputMenuStateTests|MenuBarOutputTests|OutputDeviceControllerTests|MenuBarMicrophoneTests|MicrophoneControllerTests|WatchingController|MenuBarView|ChannelHealth|AppState|ManualRecording|DualSourceRecorderLifecycleTests|WatchLoopSilencePromptTests' (424 tests, pass), ./scripts/lint.sh (0 violations), ./scripts/pre-push.sh --with-appstore (pass), swiftlint analyze --strict on a clean xcodebuild (0 violations)
- PRs: