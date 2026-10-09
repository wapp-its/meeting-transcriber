---
satisfies: [R1, R6]
---
# gh-46-pause-and-resume-a-recording.6 Pause controls: menu, icon and automation API

## Description
The user-facing controls on top of task 4's `WatchLoop.pauseRecording()` / `resumeRecording()`: the Pause/Resume menu item, the paused mark on the menu bar icon, the `pause` / `resume` verbs and `paused` field on `/v1/record`, `recordingPaused` on `/state`, and the API docs (spec: Architecture "Controls"; Edge Cases "Pause before capture is up", "Live captions during a pause"; R1 menu and icon; R6). Needs task 4.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift` (or a new `WatchingController+Pause.swift`), `RecordStatusDTO.swift`, `AppState+RPC.swift`, `RPCStateSnapshot.swift`, `AppState.swift`, `MenuBarView.swift`, `MeetingTranscriberApp.swift`, `MenuBarIcon.swift`, `A11yID.swift`, `docs/automation-api.md`, `docs/stream-deck.md`; tests
**Touches:** [app/MeetingTranscriber/Sources/WatchingController*.swift, app/MeetingTranscriber/Sources/RecordStatusDTO.swift, app/MeetingTranscriber/Sources/AppState*.swift, app/MeetingTranscriber/Sources/RPCStateSnapshot.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/MenuBarIcon.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/WatchingControllerRecordControlTests.swift, app/MeetingTranscriber/Tests/RPCRecordStatusTests.swift, app/MeetingTranscriber/Tests/DebugRPCServerIntegrationTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift, app/MeetingTranscriber/Tests/MenuBarIcon*Tests.swift, app/MeetingTranscriber/Tests/__Snapshots__/MenuBarIconSnapshotTests/**, docs/automation-api.md, docs/stream-deck.md]

## Approach
- **One entry point.** `WatchingController` gets `pauseRecording()` and `resumeRecording()` returning the loop's outcome (nil loop → `nothingToPause` / `unchanged`), plus `togglePause()` for the menu. Do not call `liveTranscription.flush()` on pause: it retires both caption feeds (`LiveTranscriptionController.flush()` → `retireFeeds()`), and only the next recording's preparation binds fresh ones, so captions would stop for the rest of the recording (spec Edge Cases "Live captions during a pause"). `WatchingController.swift` is at 580 lines: put this in an extension file.
- **API.** `RecordAction` (`RecordStatusDTO.swift:78-82`) gains `pause`, `resume`; `applyRecordAction` (`WatchingController+RecordControl.swift:55-65`) joins starts first as it does now, then maps `pause`: `changed` → `.changed`, `unchanged` → `.unchanged`, `nothingToPause` → `.blocked` (409); `resume`: `changed` → `.changed`, otherwise `.unchanged`. Unlike `start`/`stop`, these act on whichever recording runs (spec A4), so do not route them through `isRecordingMicrophoneOnly`. Update the `RecordControlOutcome.blocked` doc (`:100`). `RecordStatusDTO` gains `paused: Bool` (`.notRecording` → false); `recordStatusDTO()` (`AppState+RPC.swift:148-166`) fills it from `watching.watchLoop?.isPaused`. The route (`DebugRPCServer+V1.swift:208-218`) needs no new code; update its doc lines (`:77-78`). `/state`: `RPCStateSnapshot` gains `recordingPaused: Bool` (defaulted in the init at `RPCStateSnapshot.swift:455-472`), filled beside `isManualRecording` (`AppState+RPC.swift:89`).
- **Icon.** `BadgeKind` and `BadgeKind.compute` stay unchanged (spec A7). `MenuBarIcon.image(...)` (`MenuBarIcon.swift:139-166`) gains `pausedOverlay: Bool = false`: when set, the body draws a static pause symbol (two rounded vertical bars in the icon's own colour) instead of `drawBadgeBody`'s waveform, on frame 0 whatever the animation frame, as a template image unless a red overlay forces the explicit-colour path; the watching dot, record-only dot and permission badge draw on top as today. Render it through `renderImage` (or a second cache) rather than the badge-keyed cache. `AnimatedMenuBarIcon` (`MeetingTranscriberApp.swift:20-52`) takes and passes the flag; `menuBarLabel` (`:162-176`) passes `appState.isRecordingPaused`, a new single-member accessor in `AppState` next to `hasPermissionProblem` (`AppState.swift:493`) for the 300 ms type-check budget. gh-49 and gh-58 add their own flags next to this one; whichever lands second keeps the others.
- **Menu.** `MenuBarView` (`MenuBarView.swift:3-28`) gains `isRecordingPaused: Bool` and `onTogglePause: (() -> Void)?`; when `onTogglePause` is set, on the line directly under "Stop Recording" (spec D5, issue #98): inside gh-94's `sessionControls` section under the status line once gh-94 task .4 has landed, otherwise right after "Stop Recording" in `watchControls` (`:123-175`), a button "Pause Recording" (`pause.circle`) or "Resume Recording" (`record.circle`) with `.accessibilityIdentifier(A11yID.pauseResumeRecording)` (new constant in `A11yID.swift`). Shown for every recording kind, unlike "Stop Recording", which only manual recordings get. Wire in `MeetingTranscriberApp.swift:134-159`: `onTogglePause` non-nil only while `watching.watchLoop?.canPause == true`. Keep new view pieces in their own computed properties (type-check budget note at `MenuBarView.swift:50-55`); give the new init parameters defaults so `Tests/MenuBarViewTests.swift:32-60` keeps compiling.
- **Docs.** `docs/automation-api.md`: endpoint table (`:67-69`), `GET`/`POST /v1/record` (`:277-339`: verbs, that pause/resume act on any recording unlike stop, 409 for `pause` with nothing recording, 400 now lists five verbs), `RecordStatusDTO` (`:536-575`: JSON example, `paused` always present, field text), the status-code table (`:576-588`), and a note that `badge` stays `recording` while paused. `docs/stream-deck.md`: a short "Pausing a recording" recipe in the `/v1/record` section (`:126-148`) and the 409 row (`:195-203`); say `mt-cli` has no pause verb yet.

## Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift` and `RecordStatusDTO.swift` — verbs, outcomes, DTO
- `app/MeetingTranscriber/Sources/MenuBarIcon.swift:100-260` — cache, `image`, `renderImage`, `drawBadgeBody`
- `app/MeetingTranscriber/Sources/MenuBarView.swift:3-175` and `MeetingTranscriberApp.swift:20-52, 130-176` — menu and icon wiring
- `app/MeetingTranscriber/Tests/WatchingControllerRecordControlTests.swift` — outcome tests with `makeWatchingController` and `MockRecorder`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/RPCRecordStatusTests.swift:57-75` — wire-shape pin to extend
- `app/MeetingTranscriber/Tests/DebugRPCServerIntegrationTests.swift:1206-1290` — `/v1/record` route tests
- `app/MeetingTranscriber/Tests/MenuBarIconTests.swift`, `MenuBarIconSnapshotTests.swift` (dev-only, skipped on CI) — icon tests
- `app/MeetingTranscriber/Tests/MenuBarViewTests.swift:170-225` — menu button tests

## Key context
- GUI testing rule (CLAUDE.md "GUI Testing"): one ViewInspector wiring test for the new item, found by its `A11yID` constant; label variants are cheap extra assertions; menu-bar dropdown interaction itself is manual QA.
- A Stream Deck plugin renders `badge`; keeping it `recording` while paused is deliberate (spec A7).
- Commit messages are written for the original project's readers: no fork issue numbers or spec ids.

## Acceptance
- [ ] `WatchingControllerRecordControlTests`: `pause` on a microphone-only recording, an app recording and an auto-detected meeting returns `.changed` and the loop is paused; a repeat is `.unchanged`; `pause` with nothing recording returns `.blocked`; `resume` returns `.changed` when paused and `.unchanged` when not paused or nothing records; `start`/`stop`/`toggle` behave as before.
- [ ] `RPCRecordStatusTests`: the wire shape includes `paused`; it is true while the loop is paused whatever the recording kind, and `badge` still reads `recording`. `/state` carries `recordingPaused`. `DebugRPCServerIntegrationTests`: `POST {"action":"pause"}` mapped to `.blocked` answers 409 with the status body; an unknown verb still answers 400.
- [ ] `MenuBarViewTests`: one wiring test finds the item by `A11yID.pauseResumeRecording`, taps it and sees the callback; the label reads "Pause Recording" / "Resume Recording" by state; the item is absent when `onTogglePause` is nil.
- [ ] `MenuBarIconTests`: with `pausedOverlay` the image differs from every recording frame, is identical across animation frames, stays a template image without red overlays, and other overlays still draw over it; `BadgeKindComputeTests` and `RPCBadgeStateTests` unchanged. Add the paused image to `MenuBarIconSnapshotTests` (record the reference locally; dev-only).
- [ ] `docs/automation-api.md` and `docs/stream-deck.md` describe `pause`, `resume`, `paused`, the 409 and the unchanged `badge`.
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'RecordControl|RPCRecordStatus|RPCBadge|DebugRPCServerIntegration|MenuBar|BadgeKind|WatchingController|AppState' > <scratch>/t6.log 2>&1` green (read the log; socket tests need a normal shell).
- [ ] `./scripts/lint.sh` clean with the pinned tools; `./scripts/pre-push.sh --with-appstore` passes (release build, both variants).

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
