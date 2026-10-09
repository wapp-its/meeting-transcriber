---
satisfies: [R3]
---
# gh-43-microphone-in-the-menu-and-the-meeting.3 MicrophoneController applies a changed choice to the running recording and tracks the recorded device

## Description
App target. New `MicrophoneController`, the one owner of "which microphone" state in the app: it hands a changed choice to the running recording (R3's app half, Settings and the menu alike) and publishes the device the recording is capturing from. Attached and detached by the same recording state transitions that drive channel-health monitoring. The device list and the menu come in task .4, the probe in task .5; keep this class small and leave room for them (no placeholders for their state).

**Size:** M
**Files:** new `app/MeetingTranscriber/Sources/MicrophoneController.swift`, `app/MeetingTranscriber/Sources/AppState.swift` (construction and one stored property), `app/MeetingTranscriber/Sources/WatchingController.swift` (optional init parameter, two calls in the state-change handler), `app/MeetingTranscriber/Tests/XCTestCase+WatchingController.swift` (optional pass-through), new `app/MeetingTranscriber/Tests/MicrophoneControllerTests.swift`, `docs/architecture-macos.md`
**Touches:** [app/MeetingTranscriber/Sources/MicrophoneController.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/WatchingController.swift, app/MeetingTranscriber/Tests/XCTestCase+WatchingController.swift, app/MeetingTranscriber/Tests/MicrophoneControllerTests.swift, docs/architecture-macos.md]

### Approach
- **Tests first** (`MicrophoneControllerTests`, `@MainActor`, settings on a private `UserDefaults` suite like `Tests/EngineSettingsRuntimeSyncTests.swift:12-37`, a `MockRecorder` from task .2): a changed `micDeviceUID` while attached reaches `selectMicrophone` with the UID, and `""` reaches it as nil; a change while detached, or after `recordingStopped()`, reaches nothing; a recording whose source captures no microphone gets no call; `tick()` copies the recorder's `micInputDevice` into `recordedDevice`; `recordingStopped()` clears it. Observation fires asynchronously: await a main-actor hop before asserting, as the engine-sync tests do.
- `MicrophoneController` (`@Observable @MainActor final class`): `init(settings: AppSettings)`; `func recordingStarted(source: RecordingSource, meetingAppName: String?, recorderProvider: @escaping @MainActor () -> (any RecordingProvider)?)`, `func recordingStopped()`, `private(set) var recordedDevice: MicInputDevice?`, internal `func tick()` that tests call directly. Store the attachment (source, app name, provider) as one optional value so a stop clears all of it.
- Settings observation: self-re-arming `withObservationTracking` on `settings.micDeviceUID`, exactly the shape of `EngineController.observeEngineSettings` (`EngineController.swift:120-142`: read in the tracking closure, act and re-arm inside a `Task { @MainActor }` in `onChange`). On a change: when attached and `source.capturesMicrophone`, call `recorderProvider()?.selectMicrophone(deviceUID: uid.isEmpty ? nil : uid)`. The capture library already ignores a repeat of the current choice.
- Ticking: a `Task { @MainActor }` loop with a 1 s sleep started in `recordingStarted` and cancelled in `recordingStopped`, like `ChannelHealthController.start`/`stop` (`ChannelHealthController.swift:165-220`); each iteration calls `tick()`. A second `recordingStarted` while attached replaces the attachment without a second loop.
- Wiring in `WatchingController.attachStateChangeHandler` (`WatchingController.swift:540-579`): on `.recording`, next to `channelHealth.start`, call `microphone?.recordingStarted(source:meetingAppName:recorderProvider:)` with the loop's `activeRecordingSource`, the app name (`loop?.manualRecordingInfo?.appName ?? loop?.currentMeeting?.pattern.appName`), and `{ [weak self] in self?.watchLoop?.activeRecorder }` (the recorder is assigned after this transition fires, hence a provider, not a value); in both other arms, next to `channelHealth.stop()`, call `microphone?.recordingStopped()`. `WatchingController` takes `microphone: MicrophoneController? = nil` as a new init parameter so existing constructions compile; the file is 580 lines (SwiftLint `--strict` caps at 600), so keep additions to those few lines.
- `AppState` (`AppState.swift:240-262`): construct `MicrophoneController(settings:)` before `watching`, store it as `let microphone: MicrophoneController`, pass it to `WatchingController`. The file is 583 lines; anything beyond the stored property and the construction goes into a new `AppState+Microphone.swift` (task .4 adds the menu state there).
- Add one wiring test through `makeWatchingController` (extend the helper with an optional `microphone:` pass-through): a manual microphone recording attaches the controller, stopping it detaches it.
- `docs/architecture-macos.md`: a row for `MicrophoneController.swift`, and add `microphone` to the `AppState.swift` row's controller list.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/EngineController.swift:118-142` — self-re-arming observation
- `app/MeetingTranscriber/Sources/ChannelHealthController.swift:160-225` — per-recording start/stop with a polling task and a recorder provider
- `app/MeetingTranscriber/Sources/WatchingController.swift:532-579` — the state-change handler
- `app/MeetingTranscriber/Sources/WatchLoopState.swift:43-50` — `activeRecordingSource`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/XCTestCase+WatchingController.swift` — controller factory
- `app/MeetingTranscriber/Sources/RecordingSource.swift` — `capturesMicrophone` / `capturesAppAudio`

### Key context
- `withObservationTracking`'s `onChange` runs before the new value is stored; read the value inside the main-actor task, never in `onChange` itself.
- The `.recording` transition fires before `WatchLoop` assigns `activeRecorder` (`WatchLoop.swift:379-393`), so a provider that returns nil early is normal; the first tick or the next change picks the recorder up.
- Run: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<dir>/home swift test --parallel --filter 'MicrophoneController|WatchingController|AppState' > /private/tmp/<dir>/app.log 2>&1`, read the log. Lint with the pinned tools.

## Acceptance
- [ ] `MicrophoneController` exists, is owned by `AppState` as `microphone`, and is attached on the recording transition and detached on every other transition by `WatchingController`'s state-change handler (a wiring test through `makeWatchingController`).
- [ ] While attached to a recording that captures the microphone, a change of `settings.micDeviceUID` calls the recorder's `selectMicrophone` once with the new UID (`""` as nil); detached, after stop, or for a recording without a microphone, it calls nothing (R3, spec A5).
- [ ] `tick()` publishes the recorder's `micInputDevice` as `recordedDevice`; `recordingStopped()` clears it and ends the 1 s loop.
- [ ] `AppState.swift` and `WatchingController.swift` stay under 600 lines; existing `WatchingController*` and `AppState*` suites pass; `./scripts/lint.sh` passes.
- [ ] `docs/architecture-macos.md` has a row for `MicrophoneController.swift` and lists `microphone` in the `AppState.swift` row.


## Done summary
A microphone chosen in Settings → Audio (or, from task .4, in the menu) during a recording now reaches that recording at once. The new `MicrophoneController`, owned by `AppState` as `microphone`, observes `AppSettings.micDeviceUID` and, while it is attached to a recording that captures the microphone, calls the recorder's `selectMicrophone` with the new UID (the empty System Default choice as nil). A stopped recording, or one with no microphone track, gets nothing. While attached it ticks once a second and publishes `recordedDevice`, the device the recorder reports. `WatchingController`'s state-change handler attaches it on the `.recording` transition, next to channel-health monitoring, with the loop's source, the app name and a provider for the loop's recorder, and detaches it on every other transition.

Tests (`MicrophoneControllerTests`, 5): `testAChoiceChangedDuringARecordingReachesItsRecorderOncePerChange` (one call per change, `""` as nil), `testAChoiceReachesNoRecordingThatHasStoppedOrRecordsNoMicrophone` (after stop, app-only, with a live control), `testTheRecordedDeviceIsTheRecordersUntilTheRecordingStops` (`tick()` publishes, stop clears, a later tick does not bring it back), `testTheRecordedDeviceFollowsTheRecorderOnItsOwnWhileAttached` (the 1 s loop repeats), `testAMicrophoneRecordingAttachesTheControllerAndStoppingItDetachesIt` (wiring through `makeWatchingController`: attach with `.micOnly` and app name `Microphone`, a change reaches the loop's recorder, the stop detaches).
Mutation check: each of six defects turned a test red: no microphone-capture guard, stop keeping the attachment, `""` passed through, the stop call missing from the default arm, a loop that never repeats, the attach call missing from the handler.
Baseline: green. The focused filter `MicrophoneController|WatchingController|AppState` passed 147 tests and lint found 0 violations in 714 files.
Gates at HEAD 1e4756cf: focused filter `MicrophoneController|WatchingController|AppState` 152 tests, rc 0. `ChannelHealthIntegration|MenuBarIconTests` (the readers of the moved accessors) 68 tests, rc 0. `./scripts/lint.sh` 0 violations in 717 files. `swift build` rc 0. A clean `xcodebuild build-for-testing` followed by `swiftlint analyze --strict` found 0 violations in 644 files. Line counts: `AppState.swift` 587, `WatchingController.swift` 592.

Decision: `micSilentOverlay` and `appSilentOverlay` move unchanged from `AppState.swift` into the new `AppState+Microphone.swift` (own commit 0f4010f1) · rule 6 (the conductor's call) · `AppState.swift` was at 599 lines, and the pair is a self-contained set of menu-bar accessors of the kind task .4 adds there.
Decision: the `WatchingController(...)` arguments in `AppState.init` are now grouped several per line · rule 6 · the init body was already at SwiftLint's 60-line `function_body_length` limit, and the two new lines made it 62. `PipelineController(...)` in the same init already uses this style.
Decision: `MicrophoneController.attachment` is internal-read (`private(set)`) and observed · rule 6 · the wiring test reads it, and task .5 needs the app name it stores.
Decision: the wiring test's controller observes the test's own settings, not the factory's · rule 6 · the factory builds its settings after the controller has to exist, and the task asks for a plain `microphone:` pass-through.
Decision: no test reads the loop's cancellation directly · rule 6 · the cancellation cannot be seen without a test-only accessor. The stop clearing the attachment is tested, which makes any later tick a no-op, and a restart after a stop is guarded by `tickTask == nil`.
Decision: the review ran with `CODEX_SANDBOX=workspace-write` and `FLOW_VALIDATE_REVIEW=1`, as the owner's standing override for this run requires · rule 1 · `git status` afterwards showed nothing written outside flowctl's own `.flow` state.

Follow-ups: none filed by this task.
Feature map: no user route changed (no UI in this task).

Tier: session (jev-unavailable(no_key)) — explicit routing block: implementer opus at xhigh

stage: impl-review - ran [2026-10-09T07:26:42Z..2026-10-09T07:33:35Z] codex gpt-5.6-sol at xhigh (receipt model gpt-5.6-sol, effort xhigh). Three draws (correctness, contracts, integration), all SHIP with no findings. The validator was not dispatched because the verdict was SHIP. The round was merged through `--merged-file` because the contracts and integration draws' text did not parse for the merge-plan route.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 0f4010f1f545f3fd87bd5d7c2bfc0d599ab0aba1, 1e4756cf3846b409c0d2e5a8a9c9e57345abae7e
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh43-home swift test --parallel --filter 'MicrophoneController|WatchingController|AppState' (152 tests, rc 0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh43-home swift test --parallel --filter 'ChannelHealthIntegration|MenuBarIconTests' (68 tests, rc 0), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (0 violations, 717 files), xcodebuild clean build-for-testing + swiftlint analyze --strict (0 violations, 644 files)
- PRs: