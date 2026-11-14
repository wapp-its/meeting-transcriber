---
satisfies: [R1, R2, R3, R4, R5, R6, R7]
---
# gh-150-audio-devices-window-with-live-levels.1 Implement Audio devices window with live levels

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
The menu bar's Audio Devices section now ends with "Device Details…". It opens a read-only Audio Devices window: every microphone and output with its marks (Recording, Paused, Used by <App>, In use, Status unknown, Default, Not connected, Warning) and, during a recording, 12-segment live levels for what the recording captures. Core Audio readings run off the main thread, one at a time, only while the window is open; a reading out for 2 s turns its rows unknown. `/state.audioDevicesWindow` and `POST /action/openAudioDevices` / `/action/closeAudioDevices` expose the window to the debug RPC.

stage: impl-review - ran (codex gpt-6-astra xhigh; round 1: three reviewers, NEEDS_WORK, 2 findings, both validated and fixed; round 2: one reviewer, SHIP)

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

baseline: green (warm build rc=0; 93 focused tests, 0 failures; lint 0 violations)

Gates on the final tree:
- `swift build -j 6 --build-tests`: rc=0
- focused `swift test --skip-build --filter` over the 17 touched or new classes: 213 tests, 0 failures
- `./scripts/lint.sh` with the pinned tools: 0 violations

Wiring checks (CONTRIBUTING, Tests): each production wiring line was replaced with a constant, and its test went red. Lines checked: menu item placement, item action, `/state` field, debug route, `onAppear` → reader, levels source, configured microphone, recorded-microphone track flag, default input UID, off-main queue, and both review fixes.

Unverified:
- Validation step 6 (the live check) was not run: it needs the installed dev app with this build (after merge and mt-update).
- "A second choice opens no second window" rests on the single-instance `Window` scene. The scene wiring in `MeetingTranscriberApp` (scene, `showAudioDevices` action, `.showAudioDevices` observer) is not reachable by unit tests; the live check covers it through `/state.windows`.
- Pause wiring (`watching.isRecordingPaused` into the window state) has no AppState-level test, because it needs a running watch loop. The pure state test covers what Paused shows.
- `AppStateAudioDevicesTests.testTheWindowListsTheDevicesTheMenuEntriesOffer` reads the machine's real device lists. On a runner without audio devices it checks only the not-connected row.

Route change for the feature map: a new menu item, menu bar → Audio Devices section → "Device Details…", opens the Audio Devices window.

Decisions:
- Default input UID taken from the same `MicInputDevice.systemDefaultInput()` read as its name (rule 1: the spec names it as a value the app holds from that call).
- Output rows reuse `OutputMenuState.resolve` items, hint and warning (rule 1: "every output the Output entry offers").
- "Unnamed device" for a name that is empty or equal to the UID, in both groups and in /state (rule 6, privacy).
- An overdue reading is dropped when it returns, and the next reading answers its rows (rule 6; spec: "until a later reading returns").
- Rows read unknown before the first reading returns (rule 6).
- In use comes from the device-wide `kAudioDevicePropertyDeviceIsRunningSomewhere`, so a headset's input and output rows both show it (rule 1).
- Levels come from `ChannelHealthController`'s stored track levels (rule 1, spec Architecture).
- `selfRunningInput` is null when this process has no process object, or its translation failed (rule 6).
- Menu icon is SF Symbol `chart.bar` (rule 1, D7's three-bar level icon).
- The open action calls `bringWindowToFront` directly; it activates the app, so no separate `NSApplication.activate` (rule 6).
- `AppState.init` gained `audioDeviceRead` (default: the Core Audio read), so the /state tests can hang the reading (rule 6; no test-only API).
- The pid list "do not ask" is an empty array, not nil (rule 6, `discouraged_optional_collection`). Optional booleans stay where null is the R7 wire contract, each with a reasoned suppression (rule 1).
- Review fix: `MeetingMicrophoneProbe.RawReads.processObject` now returns `Reading<AudioObjectID?>`, keeping a failed translation apart from "no process object". The meeting microphone probe still skips both, unchanged (rule 6).
- Code commits carry no `Task:` trailer or spec id (rule 1: fork rule, commit messages written for the original's readers). The receipt commit names the task.
- Reviews ran with `CODEX_SANDBOX=workspace-write`, as the conductor's brief set. The impl-review skill lists this as an anti-pattern. After each round only flowctl bookkeeping under `.flow/` had changed; there were no reviewer writes to revert.

Assumptions:
- Meeting audio row named "Meeting app" (and the mark "Used by the meeting app") when the recording has no app name · alternatives: B — the tapped app's bundle name; C — "Unknown app" · flip at: `AudioDevicesWindowState.swift:meetingAudioRow` and `Mark.label(meetingApp:)` · test: `AudioDevicesWindowStateTests.testTheRecordingDecidesTheMeetingAudioGroupAndTheMicrophoneBar`
- Capsule colours for the marks A8 leaves open: Paused, Not connected and Status unknown grey; Warning orange as A8 says · alternatives: B — Paused yellow; C — Not connected red · flip at: `AudioDeviceMarkView.swift:tint` · test: `AudioDevicesViewTests.testTheWindowRendersItsGroupsRowsMarksAndFooterWithNoControl`
- Fixed window width 520 pt, size set by its content · alternatives: B — resizable window; C — width from the longest device name · flip at: `AudioDevicesView.swift:AudioDevicesView.body` (`.frame(width:)`) and `AudioDevicesScene.windowResizability` · test: `AudioDevicesViewTests.testTheWindowRendersItsGroupsRowsMarksAndFooterWithNoControl`

Follow-ups:
- The meeting microphone probe (`MeetingMicrophoneProbe.read`) still treats a failed PID translation like a process without an audio object. This predates this task; the seam now tells the two apart.
- Live check (Validation step 6) after merge and mt-update: open "Device Details…" twice during a call and confirm one window, the bars and the marks, and that `/state.audioDevicesWindow.selfRunningInput` stays false while no recording runs.

Memory captured: `bug/runtime-errors/a-deadline-checked-only-by-the-polling-2026-11-14`, `bug/runtime-errors/core-audio-pid-translation-folded-a-2026-11-14`.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 66098aced2f2eaeb97f37d720a08096f1ca1dfc4, 3f2afd131b552a9ea50e3392bf8d214ca5103b23, 50b1eb7042792183e0083c93ede414a16732f746, 00d0d4e359d46296a9a108e55f31c0e49ff2ff88, 25898c136469e93ab42f273f24d384b1f815e336, 8967196e19d2577d9a517611740e3c2344f3f33d, b7736de9aa9da88d2ed7e906d8d96e67ee514c01
- Tests: cd app/MeetingTranscriber && swift build -j 6 --build-tests (rc=0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --skip-build --filter 'AudioDevicesWindowStateTests|AudioDevicesWindowReaderTests|AppStateAudioDevicesTests|AudioDevicesViewTests|AudioDevicesRPCTests|MenuBarMenuOrderTests|MicrophoneControllerTests|MicrophoneControllerMeetingProbeTests|MenuBarOutputTests|MenuBarMicrophoneTests|DebugRPCServerTests|RPCWindowSnapshotTests|AppStateRPCActionsTests|MenuBarViewTests|ViewInspectorIdentifierTests|MeetingMicrophoneProbeTests|AppStateConsentPromptTests' (213 tests, 0 failures), ./scripts/lint.sh (0 violations)
- PRs: