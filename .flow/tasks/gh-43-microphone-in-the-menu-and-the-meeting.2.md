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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
