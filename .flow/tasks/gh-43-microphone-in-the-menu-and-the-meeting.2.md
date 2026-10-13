---
satisfies: [R4]
---
# gh-43-microphone-in-the-menu-and-the-meeting.2 Recorder exposes microphone device, tapped processes and switch; next recording reads the current choice

## Description
App target. Two small seams the later tasks need, plus the R4 fix: (1) the recorder roles expose the capture's microphone device, the tapped process ids and a "select microphone" call, forwarded to task .1's AudioTapLib API; (2) the watch loop reads the chosen microphone at every recording start instead of copying it when watching starts, so a change made while watching is on reaches the next recording. No UI here.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/AudioCapturing.swift`, `app/MeetingTranscriber/Sources/RecordingProvider.swift`, `app/MeetingTranscriber/Sources/DualSourceRecorder.swift` (one stored property), new `app/MeetingTranscriber/Sources/DualSourceRecorder+Microphone.swift`, `app/MeetingTranscriber/Sources/WatchLoop.swift`, `app/MeetingTranscriber/Sources/WatchingController.swift`, `app/MeetingTranscriber/Tests/MockRecorder.swift`, `app/MeetingTranscriber/Tests/TestHelpers.swift`, `app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift`, new `app/MeetingTranscriber/Tests/WatchLoopMicrophoneChoiceTests.swift`, `docs/architecture-macos.md`
**Touches:** [app/MeetingTranscriber/Sources/AudioCapturing.swift, app/MeetingTranscriber/Sources/RecordingProvider.swift, app/MeetingTranscriber/Sources/DualSourceRecorder*.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/WatchingController.swift, app/MeetingTranscriber/Tests/MockRecorder.swift, app/MeetingTranscriber/Tests/TestHelpers.swift, app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift, app/MeetingTranscriber/Tests/WatchLoopMicrophoneChoiceTests.swift, docs/architecture-macos.md]

### Approach
- **Test first for R4:** in the new `WatchLoopMicrophoneChoiceTests`, build a loop whose closure reads a mutable value, start and stop one manual recording, change the value, start another, and assert `MockRecorder.capturedMicDeviceUID` is the new value (fails today because `WatchLoop` stores a `let`). Add one through `WatchingController` (`makeWatchingController` in `Tests/XCTestCase+WatchingController.swift`, a `MockRecorder` via `makeRecorder:`): change `settings.micDeviceUID` after watching started, then a manual recording start sees the new UID. `WatchingControllerTests.swift` is at the 600-line cap, so new tests go in the new file.
- `WatchLoop` (`WatchLoop.swift:48`, init param `:132`, assignment `:155`, uses `:260` and `:390`): turn `let micDeviceUID: String?` into `let micDeviceUID: () -> String?` (init default `{ nil }`), call it at both starts. The file is **597 lines** and SwiftLint `--strict` caps at 600: keep the net line count at zero (reuse the existing doc comment line for `verboseDiagnostics` style, or move an existing helper to an extension file if a comment is needed).
- `WatchingController` (`WatchingController.swift:247` and `:473`): pass `{ [settings] in settings.micDeviceUID.isEmpty ? nil : settings.micDeviceUID }`. File is 580 lines.
- `TestHelpers.makeTestWatchLoop(micDeviceUID: String?)` (`TestHelpers.swift:229-253`) keeps its `String?` parameter and wraps it in a closure, so existing tests (`WatchLoopTests.testStartManualRecordingThreadsRecorderParams`) stay unchanged.
- `AudioCapturing` (`AudioCapturing.swift:18-36`): add `var micInputDevice: MicInputDevice? { get }`, `var microphoneTrackActive: Bool { get }` and `func selectMicrophone(deviceUID: String?)` as required members (the file explains why this role takes no defaults); update `FakeCaptureSession` in `DualSourceRecorderLifecycleTests.swift:22-47` (record select calls, settable device).
- `RecordingProvider` (`RecordingProvider.swift:5-49`, defaults `:51-79`): add `micInputDevice` (default nil), `microphoneTrackActive` (default false), `tappedPIDs: [pid_t]` (default `[]`) and `selectMicrophone(deviceUID:)` (default no-op). `MockRecorder` (`Tests/MockRecorder.swift:24-88`) gets settable `micInputDevice`, `microphoneTrackActive`, `tappedPIDs` and a recorded list of select calls for tasks .3 and .5.
- `DualSourceRecorder`: one stored property in the main file (577 lines), `private(set) var tappedPIDs: [pid_t] = []`, assigned the `effectivePids` (`DualSourceRecorder.swift:436`) after `session.start()` succeeded and cleared in `stop()`; the forwarders (`micInputDevice` → `captureSession?.micInputDevice`, `microphoneTrackActive` → `captureSession?.microphoneTrackActive ?? false`, `selectMicrophone` → `captureSession?.selectMicrophone`) live in the new `DualSourceRecorder+Microphone.swift`. Add a lifecycle test: forwarding reaches the fake session, `tappedPIDs` is empty before start and after stop.
- `docs/architecture-macos.md`: a row for `DualSourceRecorder+Microphone.swift`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchLoop.swift:40-160` and `:240-270`, `:376-395` — the stored setting and both start paths
- `app/MeetingTranscriber/Sources/AudioCapturing.swift` — role and the "required, not defaulted" rationale
- `app/MeetingTranscriber/Sources/RecordingProvider.swift` — role and its defaults
- `app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift:15-60` — fake capture session and recorder factory

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/XCTestCase+WatchingController.swift` — controller factory for tests
- `app/MeetingTranscriber/Tests/WatchLoopTests.swift:186-202` — existing threading test to keep green

### Key context
- `MicInputDevice` comes from AudioTapLib (made public in task .1); `import AudioTapLib` where needed.
- Run: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<dir>/home swift test --parallel --filter 'WatchLoop|WatchingController|DualSourceRecorder|ManualRecording' > /private/tmp/<dir>/app.log 2>&1` and read the log (never pipe into tail/head/grep). Suites that download models (Parakeet E2E, ModelPreload, LiveCaption, `WhisperKitLocalSnapshotTests.testProductionLocatesARealFetchedModel`) fail under a fresh scratch home for environmental reasons; they are not this task's regressions, CI is the gate.
- Lint: `./scripts/lint.sh` with the pinned tools (`scripts/tool-versions.sh`).
## Acceptance
- [ ] `WatchLoop` reads the microphone choice through a closure at every recording start; a test changes the value between two recordings of one loop and the second start receives the new UID, and a `WatchingController` test shows a `settings.micDeviceUID` change after watching started reaches the next recording without restarting watching (R4).
- [ ] `AudioCapturing` requires `micInputDevice`, `microphoneTrackActive` and `selectMicrophone(deviceUID:)`; `RecordingProvider` has `micInputDevice`, `microphoneTrackActive`, `tappedPIDs` and `selectMicrophone(deviceUID:)` with nil / false / empty / no-op defaults; `MockRecorder` exposes settable values and records select calls.
- [ ] `DualSourceRecorder` forwards the three members to its capture session and reports the tapped process ids for the recording's lifetime only (empty before start and after stop), covered by a lifecycle test with the fake capture session.
- [ ] `WatchLoop.swift`, `WatchingController.swift` and `DualSourceRecorder.swift` stay under 600 lines; the existing `WatchLoopTests`, `WatchingController*` and `DualSourceRecorder*` suites pass unchanged; `./scripts/lint.sh` passes.
- [ ] `docs/architecture-macos.md` has a row for `DualSourceRecorder+Microphone.swift`.
## Done summary
A microphone chosen while watching is on now reaches the next recording without restarting watching: `WatchLoop` reads the choice through a closure at both recording starts (auto-detected and manual), and `WatchingController` hands it a closure over `AppSettings.micDeviceUID`. The recorder roles now carry the microphone seams the later tasks consume: `AudioCapturing` requires `micInputDevice`, `microphoneTrackActive` and `selectMicrophone(deviceUID:)`; `RecordingProvider` adds those plus `tappedPIDs` with nil / false / no-op / empty defaults. `DualSourceRecorder` keeps the tapped process ids from a successful start until stop and forwards the other three to its capture session from the new `DualSourceRecorder+Microphone.swift`. `MockRecorder` exposes settable values and records select calls in `selectMicrophoneCalls`.

Tests: `WatchLoopMicrophoneChoiceTests.testTheNextRecordingOfALoopOpensWithTheChoiceMadeSinceTheLastOne` (one loop, choice changed between two recordings), `WatchLoopMicrophoneChoiceTests.testAChoiceMadeWhileWatchingReachesTheNextDetectedMeeting` (setting changed after `startWatching`, the same watch loop's next detected meeting opens with it), `DualSourceRecorderLifecycleTests.testTheMicrophoneReachesTheSessionAndTheTappedProcessesLastTheRecording` (forwarding through `RecordingProvider` reaches the fake session; `tappedPIDs` empty before start, equal to the tapped ids during, empty after stop; no selection reaches a stopped session).
Red-to-green: commit 46f6d5dc adds the controller test alone and it failed with `XCTAssertEqual failed: ("Optional("BuiltInUID")") is not equal to ("Optional("HeadsetUID")")` (the value copied when watching started); green after 9d0ae3fd.
Baseline: green apart from the 4 `WatchLoopE2ETests` that download a WhisperKit model (environmental under the scratch home); focused filter 321 tests, lint 0 violations.
Gates at HEAD 27464261: focused filter `WatchLoop|WatchingController|DualSourceRecorder|ManualRecording` 324 tests, 319 pass, 5 fail, all `WatchLoopE2ETests` model-download cases (the 4 baseline ones plus `testResamplePathProduces16kHzForWhisperKit`, which touches only `AudioMixer` and `WhisperKitEngine`, neither changed here; the scratch home holds a partial 188 MB model): environmental, CI is their gate. `./scripts/lint.sh` 0 violations in 714 files; `swift build` rc 0; clean `xcodebuild build-for-testing` plus `swiftlint analyze --strict` 0 violations in 641 files. Line counts: `WatchLoop.swift` 592, `WatchingController.swift` 581, `DualSourceRecorder.swift` 596, `TestHelpers.swift` 600 (net zero).

Decision: `DualSourceRecorder.captureSession` went from `private` to `private(set)` so the forwarders can live in `DualSourceRecorder+Microphone.swift`; writes stay in `start`/`stop` · rule 1 · the task Approach puts the forwarders in the extension file, and the main file (596 of 600 lines) cannot hold them.
Decision: the `WatchingController` R4 test drives an auto-detected meeting on the loop built at watch start, not a manual recording · rule 6 · a manual start builds a fresh loop each time and so passed before the fix; only the watch loop shows the defect.
Decision: the lifecycle test reads the live recording through `any RecordingProvider` and the no-session answers on the recorder itself · rule 6 · CI's `swiftlint analyze` (`unused_declaration`) flagged the four new requirements when they were read only concretely, and the extension-file forwarders when they were read only through the role; the split references both and checks that the role reaches the recorder's members.
Decision: `tappedPIDs` is cleared right after `isRecording = false` in `stop()`, so a stop that throws also clears it · rule 6 · the acceptance says empty after stop, whatever the stop's outcome.
Decision: the select-call record on both doubles is `selectMicrophoneCalls: [String?]` (`private(set)`) · rule 6 · order and count are what tasks .3 and .5 assert on.

Follow-ups: none filed by this task.
Feature map: no user route changed (no UI in this task).

Tier: session (jev-unavailable(no_key)) — explicit routing block: implementer opus at xhigh

stage: impl-review - ran [2026-10-09T06:55Z..2026-10-09T07:02:51Z] codex gpt-5.6-sol at xhigh (receipt model gpt-5.6-sol, effort xhigh), three draws (correctness, contracts, integration) all SHIP, no findings; validator not dispatched (SHIP); merged through --merged-file because the integration draw's text did not parse for the merge-plan route (SHIP)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 46f6d5dc8521b48374a7fda19d553618cd664af5, 9d0ae3fd5defaf7add94530ae7230e5bd0a3453d, adb05a5248538060ce38fd98a41073ca2bbbb30f, 2746426190d8c96cebf6146d4fa2bc45b75ac03e
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh43-home swift test --parallel --filter 'WatchLoop|WatchingController|DualSourceRecorder|ManualRecording' (324 tests, 319 pass, 5 WatchLoopE2ETests model-download failures, environmental), ./scripts/lint.sh (pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1): 0 violations in 714 files, cd app/MeetingTranscriber && swift build: rc 0, xcodebuild clean build-for-testing + swiftlint analyze --strict: 0 violations in 641 files
- PRs: