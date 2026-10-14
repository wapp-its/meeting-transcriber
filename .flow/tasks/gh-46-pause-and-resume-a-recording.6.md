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
The user-facing pause controls now reach task .4's watch-loop pause. The menu shows "Pause Recording" / "Resume Recording" on the line under "Stop Recording" while a recording's capture runs, for every kind of recording. While paused, the menu bar icon draws a static pause symbol in place of the waveform, and every existing overlay still draws over it. `POST /v1/record` accepts `pause` and `resume` for any recording; a `pause` with no capture running answers 409. `GET`/`POST /v1/record` report `paused`, `/state` reports `recordingPaused`, and `badge` stays `recording`. `docs/automation-api.md` and `docs/stream-deck.md` describe all of it.

stage: impl-review - skipped(policy: parallel-wave - conductor owns the review after integration)

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

baseline: green via handoff (conductor, at e9bb94be, which is this lane's BASE_COMMIT; nothing changed since, checked with `git log --name-only e9bb94be..HEAD`), and lint measured green before any edit (`./scripts/lint.sh` with the pinned tools, rc 0, 0 violations in 798 files).

### Gates (worker, on lane commits 508db808 and 37d55bcc, all measured)

- Task AC filter `RecordControl|RPCRecordStatus|RPCBadge|DebugRPCServerIntegration|MenuBar|BadgeKind|WatchingController|AppState`, scratch home /tmp/gh46-home-t6, `--parallel`: 408 tests, rc 0, 0 failures, 0 skips. All 74 `DebugRPCServerIntegrationTests` ran (socket tests included). Log: /tmp/gh46-tick/w6/t6.log.
- `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1: rc 0, 0 violations in 800 files (log /tmp/gh46-tick/w6/lint2.log).
- `./scripts/pre-push.sh --with-appstore` (release build of both variants): rc 0 in 199 s, "OK — pre-push parity check passed." Both variants built (Homebrew, then `-DAPPSTORE`), and the log has no warning or error line. Log: /tmp/gh46-tick/w6/prepush.log.
- `flowctl gate classify --base e9bb94be`: exit 1 (FULL), so the focused commands above ran and no GATE_SKIPPED line applies.
- Snapshot: `MenuBarIconSnapshotTests.testPausedSnapshot` recorded `Tests/__Snapshots__/MenuBarIconSnapshotTests/testPausedSnapshot.recording.png` on its first run (expected "No reference was found" failure). The rerun against the committed reference was green: 8 tests, rc 0 (log /tmp/gh46-tick/w6/snapshot2.log). I looked at the reference upscaled: two upright bars, clearly not the waveform.
- Mutation check: seven one-point mutations, each applied alone, run against its test class, and restored from HEAD (tree clean afterwards). Each failed its intended test. M1: pause with nothing to pause answers `.unchanged`. M2: DTO `paused` hardcoded false. M3: `/state` `recordingPaused` hardcoded false. M4: the icon body ignores the pause. M5: menu labels swapped. M6: the menu toggle only ever pauses. M7: pause routed through the microphone-only check. Results: /tmp/gh46-tick/w6/mutations-all.txt.
- Not run: CI's `swiftlint analyze` (`unused_declaration`), which needs a clean `xcodebuild build-for-testing`. A reference exists for every new declaration (inferred clean).
- Not run, owner checks per spec: the icon's look in light and dark menu bars, and a real call paused and resumed from the menu, Stream Deck or curl.

### Tests by acceptance criterion

1. `WatchingControllerRecordControlTests`:
   - `testPauseActsOnEveryKindOfRecordingAndARepeatIsUnchanged` covers a microphone recording, an app recording and a detected meeting: `.changed`, the loop paused, the repeat `.unchanged`, the loop still recording.
   - `testWithNothingRecordingPauseIsRefusedAndResumeIsUnchanged`: `pause` is `.blocked` and `resume` is `.unchanged`.
   - `testResumeChangesOnlyAPausedRecording`: `.unchanged` while running, `.changed` while paused.
   - `testTheMenuTogglePausesThenResumesTheRunningRecording` covers the menu toggle and `canPauseRecording`.
   - The existing start/stop/toggle tests are unchanged and green.
2. `RPCRecordStatusTests`: the wire-shape pin now includes `paused`, false in `.notRecording`. `testAPauseIsReportedForEveryKindOfRecordingWithTheBadgeUnchanged` has two rows, microphone and app recording. In each, `paused` and `/state.recordingPaused` are true while paused, and `badge` is `recording` on both surfaces. `recording` keeps its microphone-only meaning, and `paused` is false after resume. `DebugRPCServerIntegrationTests`: `testV1RecordPOSTPauseWithNothingToPauseReturns409` checks that the verb reaches the seam as `.pause` and that the answer is 409 with the status body. The unknown-verb test now sends `rewind` (it used `pause`, which is now a verb) and still gets 400.
3. `MenuBarViewTests`:
   - `testThePauseItemSitsUnderStopRecordingAndCallsItsCallback` finds the item by `A11yID.pauseResumeRecording` and checks its label in both states. The item is the button right after "Stop Recording", and a tap calls the callback once.
   - `testThePauseItemIsAbsentWithoutACallback`: no item when `onTogglePause` is nil.
4. `MenuBarIconPauseTests` (new file, matching `MenuBarIcon*Tests.swift`):
   - `testThePausedIconReplacesEveryRecordingFrameAndHoldsStill`: differs from every recording frame, identical across frames.
   - `testThePausedIconIsATemplateUnlessARedOverlayIsOn`: a template image unless a red overlay is on.
   - `testEveryOverlayStillDrawsOverThePauseSymbol`: the watching dot, question mark, permission badge, record-only dot and both silent tints still draw, each with the pause symbol still under it (pixel probes).
   - `testTheCountdownPulseStillRunsOverThePauseSymbol`: the countdown pulse still runs while paused (A10).
   - `BadgeKindComputeTests` and `RPCBadgeStateTests` are untouched and green. `MenuBarIconSnapshotTests.testPausedSnapshot` was added (dev-only).
5. Docs, `docs/automation-api.md`: the endpoint table; GET and POST `/v1/record`, with a "Pausing a recording" paragraph and a curl example; the 200, 409, 400 and 503 response text; the `RecordStatusDTO` example and the `paused` and `badge` bullets; the `WatchStatusDTO` `badge` note; the 409 row of the status-code table. `docs/stream-deck.md`: a "Pausing a recording" subsection in the `/v1/record` section (says `mt-cli` has no pause verb yet) and the 409 row.
6. AC filter: the gate above.
7. Lint and pre-push: the gates above.

### Decisions

- D-a (rule 1, task Approach, spec A4): the one entry point is the new `Sources/WatchingController+Pause.swift`. It holds `pauseRecording()` and `resumeRecording()` (a nil loop gives `.nothingToPause` / `.unchanged`), `togglePause()` for the menu, and the read accessors `isRecordingPaused` and `canPauseRecording`. `applyRecordAction` joins starts first. Then `pause` maps changed/unchanged/nothingToPause to `.changed`/`.unchanged`/`.blocked`, and `resume` maps changed to `.changed` and anything else to `.unchanged`. Neither goes through `isRecordingMicrophoneOnly`. Live captions are not flushed. Test: the record-control tests, mutation M7.
- D-b (rule 5): `MenuBarIcon.swift` was at 599 of 600 lines, and the pause drawing took it to 623. An extension file (`MenuBarIcon+Pause.swift`) would be outside the declared Touches, so I added `// swiftlint:disable file_length` on line 1. `AppSettings.swift`, `PipelineQueue.swift`, `SpeakerNamingView.swift` and `DualSourceRecorder.swift` carry the same suppression. Alternative: move `drawPauseSymbol` (or the `BadgeKind.compute` extension) into a new file and drop the suppression. Switch point: `MenuBarIcon.swift` line 1. Test: `./scripts/lint.sh`.
- D-c (rule 4, icon shape): two pill-shaped bars, 3 pt wide, 11 pt tall and 3 pt apart, centred where the waveform sits, in the icon's own colour. They are drawn through `renderImage` with no cache, re-rendered per animation tick like the red overlays. The watching dot's clear ring should take a small bite out of the right bar's top corner, as it does out of the waveform (inferred from the geometry, not rendered). Alternatives: the SF Symbol `pause.fill`, square-ended bars, a paused frame cache. Switch point: `MenuBarIcon.drawPauseSymbol`. Tests: `MenuBarIconPauseTests`, the snapshot reference.
- D-d (rule 1, A10 over the task's "frame 0" wording): the pause symbol ignores the frame. The real animation frame still reaches `renderImage`, so a meeting-end countdown keeps pulsing over a paused icon. Switch point: `MenuBarIcon.image` (the frame passed with `pausedOverlay`). Test: `testTheCountdownPulseStillRunsOverThePauseSymbol`, mutation M4.
- D-e (rule 1, D5): the item is `MenuBarView.pauseResumeItem`. It is rendered in `sessionControls` after the Stop Recording / watch-toggle branch, so it is the line under "Stop Recording", and it is present exactly when `onTogglePause` is set. The scene sets the callback from `AppState.canPauseRecording` (the loop's `canPause`). The icons are `pause.circle` / `record.circle` and there is no keyboard shortcut (none requested). Test: the two `MenuBarViewTests`, mutation M5.
- D-f (rule 6): `AppState.isRecordingPaused` sits next to `hasPermissionProblem` and `AppState.canPauseRecording` next to `canStopRecording`. Both are single-hop reads through `WatchingController`, for the type-check budget. `/state` and `/v1/record` read `watching.isRecordingPaused`.
- D-g (rule 6): `paused` sits right after `recording` in `RecordStatusDTO`, is always present, and is false in `.notRecording`. The docs state that a paused detected meeting reads `recording: false, paused: true`. They also state that `pause` and `resume` answer 503 only when a start already in flight does not settle within 20 s, which is what `joinStarts` does.
- D-h (rule 1, the AC's "unknown verb still 400"): the integration test's unknown verb changed from `pause` to `rewind`. Declared intent: `pause` is now valid.

### Notes for the conductor

- Not done, outside the declared Touches: the route's doc comment in `Sources/DebugRPCServer+V1.swift:77-78` (task Approach: "update its doc lines") still reads "`POST /v1/record` — start/stop/toggle a microphone recording `{action}`, or end any recording `{"action":"stop","scope":"any"}`". Suggested replacement: "start/stop/toggle a microphone recording or pause/resume any recording `{action}`, or end any recording `{"action":"stop","scope":"any"}`". The route itself needs no code change: the 409 test drives it.
- Feature-map route change: the menu bar gains "Pause Recording" / "Resume Recording" under "Stop Recording" while a recording runs. `/v1/record` gains the `pause` and `resume` verbs.
- Touches: every changed file is inside the declared set. `WatchingController+Pause.swift` matches `WatchingController*.swift` and `MenuBarIconPauseTests.swift` matches `MenuBarIcon*Tests.swift`.
- Owner checks (spec Verification, not tasks): the paused icon in light and dark mode, and whether the bite the watching dot takes out of the right bar is acceptable.

### Review and integration (conductor)

stage: impl-review - ran [codex gpt-6-astra xhigh; round 1: three draws (correctness, contracts, integration) all SHIP, 0 findings; no fix pass]

Integrated onto feat/gh-46-pause-recording as 3934635d, edff80ee (lane commits 508db808, 37d55bcc) plus the conductor's 40aebdcf (the route doc comment in DebugRPCServer+V1.swift the task's Approach asked for, outside the worker's Touches), base e9bb94be. Focused integrated verify at 40aebdcf: task AC filter 408 tests exit 0 (socket tests included); lint exit 0. pre-push --with-appstore: worker-measured exit 0 at the lane head; run again on the final head at quiesce.

Conductor decisions on the worker's report: D-b (file_length disable on MenuBarIcon.swift) is a rule-5 assumption recorded as A14; D-c (icon shape) a rule-4 assumption recorded as A15; D-d (A10 over the task's frame-0 wording, rule 1), D-a, D-e (rule 1), D-f, D-g (rule 6) accepted; D-h (the unknown-verb integration test now sends rewind instead of pause) accepted as a requirement change: pause is a valid verb now, the test's intent (an unknown verb answers 400) is unchanged. The route doc comment (rule 6) was done by the conductor as 40aebdcf.

Owner checks (spec Verification, not tasks): the paused icon in light and dark menu bars, and whether the watching dot's bite out of the right bar is acceptable; a real call paused and resumed from the menu, Stream Deck or curl.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 3934635d2fb0699d1e9fb55cea1266798b072aa5, edff80eeafc8031ce6a9616088813bfb6d6a7276, 40aebdcfc1e9e618558d4dfe5f367d5233b5689a
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/gh46-home-c6 swift test --parallel --filter 'RecordControl|RPCRecordStatus|RPCBadge|DebugRPCServerIntegration|MenuBar|BadgeKind|WatchingController|AppState' (integrated head 40aebdcf: exit 0, 408 tests, 0 failures, 0 skipped, socket tests included), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (integrated head 40aebdcf: exit 0, 0 violations in 800 files), worker at lane head 37d55bcc (same tree minus the route doc comment): task AC filter 408 tests exit 0; lint exit 0; ./scripts/pre-push.sh --with-appstore exit 0 in 199 s (both release variants); MenuBarIconSnapshotTests rerun against the recorded paused reference exit 0; 7 single-point mutations each failed their intended test, ./scripts/pre-push.sh --with-appstore on the final integrated head: run once at quiesce (Phase 4), see the spec's work summary, review: codex gpt-6-astra xhigh, round 1 three draws (correctness, contracts, integration) all SHIP, 0 findings (receipt /tmp/impl-review-receipt-d1afe3212e3b-gh-46-pause-and-resume-a-recording.6.json), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'RecordControl|RPCRecordStatus|RPCBadge|DebugRPCServerIntegration|MenuBar|BadgeKind|WatchingController|AppState', ./scripts/lint.sh, ./scripts/pre-push.sh --with-appstore
- PRs: