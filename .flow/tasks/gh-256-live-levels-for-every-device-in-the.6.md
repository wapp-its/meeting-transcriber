---
satisfies: [R1, R2, R4, R11, R12, R13]
---
# gh-256-live-levels-for-every-device-in-the.6 Wire live bars into the Audio Devices window

## Description
Puts it together in the window: the Audio Devices window reports whether it is visible, the meters (.4, .5) are created once and fed the device lists, the microphone permission and the Screen Recording health, the reader samples their levels on its 100 ms tick and builds the state (.2), and the view renders a level column on every row with the accepted texts. After this task the feature is live in the app (spec Architecture, "One owner of the window's meters"; R1, R2, R4, R11, R12; D6 to D9).

**Size:** M
**Files:** `Sources/AudioDevicesWindowVisibility.swift` (new), `Sources/AudioDevicesView.swift`, `Sources/AudioDevicesWindowReader.swift`, `Sources/AppState+AudioDevices.swift`, `Sources/AppState.swift` (only a wiring line, if unavoidable), `Tests/AudioDevicesViewTests.swift`, `Tests/AudioDevicesWindowReaderTests.swift`, `Tests/AppStateAudioDevicesTests.swift`, `docs/architecture-macos.md`
**Touches:** [app/MeetingTranscriber/Sources/AudioDevicesWindowVisibility.swift, app/MeetingTranscriber/Sources/AudioDevicesView.swift, app/MeetingTranscriber/Sources/AudioDevicesWindowReader.swift, app/MeetingTranscriber/Sources/AppState+AudioDevices.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Tests/AudioDevicesViewTests.swift, app/MeetingTranscriber/Tests/AudioDevicesWindowReaderTests.swift, app/MeetingTranscriber/Tests/AppStateAudioDevicesTests.swift, docs/architecture-macos.md]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first for the reader and the wiring; the view gets one wiring test per state.
1. **Visibility** (D9, A16): a small AppKit bridge on the window's content finds its `NSWindow` and reports `occlusionState.contains(.visible)` on `NSWindow.didChangeOcclusionStateNotification`, miniaturise and deminiaturise (occlusion also covers another Space). `onAppear`/`onDisappear` (`Sources/AudioDevicesView.swift:35-36`) stay the open and close. An injected seam lets tests drive it.
2. **Reader:** `windowOpened()`/`windowClosed()` as today plus `visibilityChanged(_:)` handed to the meters (.5). The tick samples each meter's level with no Core Audio call and stores lit segments only on a change, as it does for the recorded levels; sampling runs only while the window is visible (Validation step 4). The reader builds `AudioDevicesWindowState` with .2's `Meters` input.
3. **Wiring** (`Sources/AppState+AudioDevices.swift:8-48`): create the meters once with the production device layer; feed them `MicrophoneController.devices` and `OutputDeviceController.devices` (on change), the microphone authorization and `PermissionsController.health` (for A12); hand WatchingController its gate and activity hook (.5). The reader owns the meters, so `AppState.swift` (583 lines, at its cap) needs no new stored property.
4. **View:** the level column on every row whenever the state shows it; paused, "Can't read", "No permission" and "Unknown" in the grey, right-aligned style of gh-150's "no level" (D7, A13); footers and hint lines from the state.
5. **Docs:** `docs/architecture-macos.md` gets the meters: their owner, lane, pause and gate, and the rows for this task's files. The measured budget comes in .7.

### Investigation targets
**Required** (read before coding):
- `Sources/AudioDevicesView.swift:15-135` — window, rows, level column
- `Sources/AudioDevicesWindowReader.swift:96-235` — init seams, open/close, tick, sampling
- `Sources/AppState+AudioDevices.swift:8-48` — where the reader and its inputs are built
- `Tests/AudioDevicesViewTests.swift:51-86` — level column and "runs only while shown" tests
- `docs/architecture/gui-testing.md` — wiring tests, A11y IDs, snapshot rules

**Optional** (reference as needed):
- `Sources/MenuBarIconFrame.swift:15-25` — an existing occlusion observer
- `Sources/AppState.swift:90, 190-240` — the reader's wiring

### Key context
- A SwiftUI body over 300 ms of type-checking fails the build (`-warn-long-function-bodies=300`); keep the row and level views small.
- `MeetingTranscriberApp.swift` is at 598 lines; the window scene needs no edit.
- The App Store build has the meters but no `/state`; its checks are the unit tests.

## Acceptance
- [ ] Reader tests, written first and seen failing: not visible closes the meters through the fake and stops sampling; visible again reopens them unless paused; lit segments are stored only on a change; the state carries the meters' input.
- [ ] View tests (ViewInspector): a bar on every row while running, "Paused for call" on unrecorded rows during a recording, the failure texts, the footers and the A12 line; each test fails when its wiring is removed.
- [ ] Wiring test: the meters are created once, follow the device lists, and the gate and activity hook reach WatchingController.
- [ ] Both variants build and pass their tests: the repository's test command and `./scripts/pre-push.sh --with-appstore` (Validation step 5).
- [ ] `docs/architecture-macos.md` describes the meters; `./scripts/lint.sh` clean with the pinned tools.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
