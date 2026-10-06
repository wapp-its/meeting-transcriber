---
satisfies: [R1, R2]
---
# gh-43-microphone-in-the-menu-and-the-meeting.4 Microphone entry in the menu bar menu with the shared device list

## Description
App target. The Microphone entry in the menu bar menu (R1, R2): its title, the submenu with the device list and checkmark, the off line, and the shared device list Settings also uses. The decisions live in a pure `MicrophoneMenuState.resolve`, tested arm by arm; the view gets one wiring test (menu-bar dropdown interaction itself is manual QA in this repo).

**Size:** M
**Files:** new `app/MeetingTranscriber/Sources/MicrophoneDevices.swift`, new `app/MeetingTranscriber/Sources/MicrophoneMenuState.swift`, new `app/MeetingTranscriber/Sources/AppState+Microphone.swift`, `app/MeetingTranscriber/Sources/MicrophoneController.swift` (device list), `app/MeetingTranscriber/Sources/Settings/AudioSettingsView.swift`, `app/MeetingTranscriber/Sources/MenuBarView.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, new `app/MeetingTranscriber/Tests/MicrophoneMenuStateTests.swift`, new `app/MeetingTranscriber/Tests/MenuBarMicrophoneTests.swift`, `app/MeetingTranscriber/Tests/MicrophoneControllerTests.swift`, `docs/architecture-macos.md`
**Touches:** [app/MeetingTranscriber/Sources/MicrophoneDevices.swift, app/MeetingTranscriber/Sources/MicrophoneMenuState.swift, app/MeetingTranscriber/Sources/AppState+Microphone.swift, app/MeetingTranscriber/Sources/MicrophoneController.swift, app/MeetingTranscriber/Sources/Settings/AudioSettingsView.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/MicrophoneMenuStateTests.swift, app/MeetingTranscriber/Tests/MenuBarMicrophoneTests.swift, app/MeetingTranscriber/Tests/MicrophoneControllerTests.swift, docs/architecture-macos.md]

### Approach
- **Tests first** for the pure state (`MicrophoneMenuStateTests`), one per arm: recording with a reported device → title names it; idle with a chosen, connected device → its name; idle on System Default → `System Default (<default name>)`; chosen device not connected → title names the default and says the chosen one is not connected, submenu carries a checked, disabled `Selected microphone (not connected)` item; no input device and no default name → "no microphone available"; `noMic` → one disabled `Microphone: Off (app audio only)` line, no items; items are `System Default (<name>)` then the devices in the given order; the checked UID is the stored choice (`""` for System Default); a recording whose capture reports nothing (track failed or given up) falls back to the idle title. Keep a `meetingAppHint: String?` input that only passes through to `hint` (task .5 fills it).
- `MicrophoneDevices` (new): `struct MicrophoneDevice: Equatable, Sendable { let uid: String; let name: String }`, `static func available() -> [MicrophoneDevice]` holding exactly today's discovery from `AudioSettingsView.swift:33-40` (`AVCaptureDevice.DiscoverySession([.microphone, .external], .audio, .unspecified)`, `uniqueID` / `localizedName`, same order), and `static func systemDefaultInputName() -> String?` from AudioTapLib's `MicInputDevice.systemDefaultInput()?.name` (task .1). Never name the default from `AVCaptureDevice.default(for:)` or the discovery order (spec A9).
- `AudioSettingsView`: replace its private discovery with `MicrophoneDevices.available()`; the picker and its tags stay as they are. Run `SettingsViewTests`, `SettingsInteractionTests` unchanged.
- `MicrophoneController` (task .3): add observable `devices` and `defaultInputName`, an injectable list provider and default-name provider (init parameters with the production helpers as defaults), and `refreshDevices()`. Call it at init, at `recordingStarted`, on `AVCaptureDevice.wasConnectedNotification` / `.wasDisconnectedNotification` (NotificationCenter, main queue), and from a Core Audio listener on `kAudioHardwarePropertyDefaultInputDevice` on the main queue (pattern `tools/audiotap/Sources/MicCaptureHandler.swift:361-378`; the controller lives as long as the app, so no removal is needed). Test `refreshDevices()` with injected providers.
- `AppState+Microphone.swift`: `var microphoneMenuState: MicrophoneMenuState` resolved from `settings.noMic`, `settings.micDeviceUID`, `microphone.devices`, `microphone.defaultInputName`, `microphone.recordedDevice`, and nil for the hint (task .5).
- `MenuBarView` (335 lines): new stored properties at the END of the property list with defaults, `var microphoneMenu: MicrophoneMenuState = .hidden` (or similar) and `var onSelectMicrophone: (String) -> Void = { _ in }`, so the memberwise calls in `MenuBarViewTests`/`MenuBarJobMenuTests` compile unchanged. Add a hoisted `@ViewBuilder private var microphoneSection` and reference it in `body` right after `watchControls` (`MenuBarView.swift:56-80`): `Menu(title) { Picker(selection:) { items }.pickerStyle(.inline).labelsHidden() ; hint as a disabled Text }`, or a single disabled `Text` when off. The picker binding is `Binding(get: { checkedUID }, set: onSelectMicrophone)`. Build every label string in a helper function, never inline in the `ViewBuilder`: this file's `body` already blew the 300 ms type-check budget the analyze build enforces (see the note at `MenuBarView.swift:49-55`).
- `A11yID`: `static let menuMicrophonePicker = "menuMicrophonePicker"` on the picker. No device UID or name in any identifier.
- `MenuBarMicrophoneTests` (ViewInspector, one wiring test per control, CLAUDE.md GUI Testing): find by `A11yID.menuMicrophonePicker` then `.find(ViewType.Picker.self)` (two-step lookup, CLAUDE.md "Identifiers"), `select(value: "<uid>")`, assert the closure got the UID; with `noMic` the off line is present and the picker absent.
- `MeetingTranscriberApp.menuBarContent` (`MeetingTranscriberApp.swift:131-158`): pass `microphoneMenu: appState.microphoneMenuState` and `onSelectMicrophone: { appState.settings.micDeviceUID = $0 }`.
- `docs/architecture-macos.md`: rows for the three new files; extend the `MenuBarView.swift` row (microphone entry) and the `Settings/AudioSettingsView.swift` row (shared device list).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/MenuBarView.swift` — sections, the type-check note, `jobRow` submenu
- `app/MeetingTranscriber/Sources/Settings/AudioSettingsView.swift:1-41` — today's list and picker
- `app/MeetingTranscriber/Tests/MenuBarViewTests.swift:1-65` — how the view is built in tests
- `app/MeetingTranscriber/Tests/SettingsInteractionTests.swift:40-70` — picker `select(value:)` write-back pattern

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/ViewInspectorIdentifierTests.swift` — identifier-then-picker lookup
- `app/MeetingTranscriber/Sources/A11yID.swift` — naming conventions

### Key context
- Choosing an item only writes the setting; the live restart is task .3's observer. Never call anything that changes the macOS default input (spec D1).
- The title must name the device during a recording from `microphone.recordedDevice` (refreshed each second), not from the setting (spec A8).
- Run: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<dir>/home swift test --parallel --filter 'MicrophoneMenuState|MenuBar|MicrophoneController|SettingsView|SettingsInteraction' > /private/tmp/<dir>/app.log 2>&1`, read the log. Lint with the pinned tools; `./scripts/pre-push.sh --with-appstore` once at the end (release build, both variants; the type-check budget shows there).

## Acceptance
- [ ] `MicrophoneMenuState.resolve` has a test per arm of R1 and R2: recording title from the reported device; idle title from the chosen device or `System Default (<name>)`; chosen device not connected (title and the checked, disabled `Selected microphone (not connected)` item); no input device; `noMic` off line without items; items `System Default (<name>)` first then the Settings list in order; checked UID equals the stored choice.
- [ ] Settings → Audio → Microphone and the menu read the same list from `MicrophoneDevices.available()`; the default input name comes from Core Audio via `MicInputDevice.systemDefaultInput()`; existing Settings tests pass unchanged.
- [ ] One ViewInspector test finds the menu picker by `A11yID.menuMicrophonePicker`, selects a UID and sees the selection closure receive it; with `noMic` the off line is present and the picker absent. `MenuBarViewTests` and `MenuBarJobMenuTests` compile and pass unchanged.
- [ ] `MicrophoneController.refreshDevices()` updates `devices` and `defaultInputName` from injected providers; it is called at init, at recording start, on device connect/disconnect notifications and on default-input changes.
- [ ] Selecting an item writes `settings.micDeviceUID` only (the app never changes the macOS default input); `./scripts/lint.sh` and `./scripts/pre-push.sh --with-appstore` pass.
- [ ] `docs/architecture-macos.md` has rows for the new files and updated `MenuBarView.swift` and `Settings/AudioSettingsView.swift` rows.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
