---
satisfies: [R1, R3, R5]
---
# gh-4-balance-own-voice-and-remote-levels.2 Balance switch and recording wiring

## Description
Add the switch (R5) and carry it to every place that writes a `_mix.wav` from two tracks: the recorder's `stop()` and launch-time crash recovery (R1 end to end, R3). Split from .1 because this is plumbing over a mixer already proven, and from .3 because the naming dialog is a separate consumer.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/AppSettings.swift`, `app/MeetingTranscriber/Sources/Settings/AudioSettingsView.swift`, `app/MeetingTranscriber/Sources/Settings/SettingsHelp.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Sources/DualSourceRecorder.swift`, `app/MeetingTranscriber/Sources/DualSourceRecorder+BuildRecording.swift`, `app/MeetingTranscriber/Sources/WatchingController+RecorderFactory.swift`, `app/MeetingTranscriber/Sources/PipelineController.swift`; tests `app/MeetingTranscriber/Tests/LevelBalanceSettingTests.swift` (new), `app/MeetingTranscriber/Tests/BuildRecordingLevelBalanceTests.swift` (new), `app/MeetingTranscriber/Tests/HelpBadgeTests.swift`, `app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift`, `app/MeetingTranscriber/Tests/DualSourceRecorderCrashRecoveryTests.swift`, `app/MeetingTranscriber/Tests/StagedRecoveryFolderTests.swift`, `app/MeetingTranscriber/Tests/PipelineControllerOutputFolderTests.swift`, `app/MeetingTranscriber/Tests/PipelineControllerLevelBalanceTests.swift` (new); cut-back path (spec A9, added 2026-10-07 after impl-review round 1): `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift`, `app/MeetingTranscriber/Sources/RecordingCut.swift`, `app/MeetingTranscriber/Tests/WatchLoopMeetingEndTests.swift`, `app/MeetingTranscriber/Tests/RecordingCutTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/AppSettings.swift, app/MeetingTranscriber/Sources/Settings/AudioSettingsView.swift, app/MeetingTranscriber/Sources/Settings/SettingsHelp.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Sources/DualSourceRecorder.swift, app/MeetingTranscriber/Sources/DualSourceRecorder+BuildRecording.swift, app/MeetingTranscriber/Sources/DualSourceRecorder+CrashRecovery.swift, app/MeetingTranscriber/Sources/WatchingController+RecorderFactory.swift, app/MeetingTranscriber/Sources/PipelineController.swift, app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift, app/MeetingTranscriber/Sources/RecordingCut.swift, app/MeetingTranscriber/Tests/LevelBalanceSettingTests.swift, app/MeetingTranscriber/Tests/BuildRecordingLevelBalanceTests.swift, app/MeetingTranscriber/Tests/HelpBadgeTests.swift, app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift, app/MeetingTranscriber/Tests/DualSourceRecorderCrashRecoveryTests.swift, app/MeetingTranscriber/Tests/StagedRecoveryFolderTests.swift, app/MeetingTranscriber/Tests/PipelineControllerOutputFolderTests.swift, app/MeetingTranscriber/Tests/PipelineControllerLevelBalanceTests.swift, app/MeetingTranscriber/Tests/WatchLoopMeetingEndTests.swift, app/MeetingTranscriber/Tests/RecordingCutTests.swift]

### Approach
- Setting: copy `silentTrackWatchdogEnabled` (declaration with doc comment `AppSettings.swift:248-256`, load `:665`) as `levelBalanceEnabled`, key `"levelBalanceEnabled"`, loaded with `?? true` (spec A2). The doc comment says what it changes (the saved mix and the naming samples) and what it never changes (the per-track files the pipeline reads), and that it is read when a recording starts.
- UI: in `AudioSettingsView` add a small private section struct like `EchoSection` (`AudioSettingsView.swift:73-100`), titled for example "Recording Levels", placed right after the Microphone section, holding one `HelpfulToggle` (title for example "Balance my voice and the meeting audio") with `.accessibilityIdentifier(A11yID.levelBalanceToggle)`. No `.recordOnlyDisabled`: record-only writes the mix too.
- `A11yID.levelBalanceToggle` beside its peers (`A11yID.swift:69-76`); `SettingsHelp.levelBalance` in the style of `SettingsHelp.swift:10-21`, plain English: evens out your voice and the other participants in the saved mixed recording and the speaker samples; transcription and speaker recognition always use the unchanged recordings; a very quiet microphone is raised by at most 24 dB; applies from the next recording.
- Recorder: `var levelBalanceEnabled = false` beside `silentTrackWatchdogEnabled` (`DualSourceRecorder.swift:384-389`, same doc style: set by the recorder factory before `start`). `stop()` (`:473-511`) passes it to `buildRecording`, which gains `levelBalance: Bool = false` (`DualSourceRecorder+BuildRecording.swift:36-42`) and passes it to `AudioMixer.mix` at `:193` only; the single-track branches (`:200-204`) stay as they are.
- Factory: `dualSource.levelBalanceEnabled = self?.settings.levelBalanceEnabled ?? false` next to the watchdog line (`WatchingController+RecorderFactory.swift:22-26`).
- Crash recovery: `recoverCrashedRecording(stem:in:)` (`DualSourceRecorder.swift:299`) and `recoverCrashedRecordings(in:minAge:)` (`:345`) gain `levelBalance: Bool = false` and pass it on.
- Launch recovery reaches them through `PipelineController.QueueEnvironment.recoverStagedRecordings` (`PipelineController.swift:55-72`), a callback typed `(@MainActor (PipelineQueue) -> Void)?` whose production value is the static `recoverStagedRecordings(into:)` (`:299-323`); a static function cannot read `settings`. Give the callback a second argument, the level-balance flag: `makeQueue` (`:291`, an instance method on the main actor) passes `settings.levelBalanceEnabled`, and the static function captures it into its `Task.detached` and passes it to `recoverCrashedRecordings`. Update the callers of the callback type: `Tests/StagedRecoveryFolderTests.swift:35-36` (call it with `false`, keep the injected staging folder) and `Tests/PipelineControllerOutputFolderTests.swift:86` (closure takes two arguments); `PipelineControllerTests.swift:40` and `AppStateTests.swift:44` pass `nil` and stay as they are.
- Cut-back path (spec A9, from impl-review round 1): an auto-detected meeting that ends through the end-of-meeting question is stopped and then cut back (`WatchLoop.swift:430-436` → `cutBack` in `WatchLoop+MeetingEnd.swift:81` → `RecordingCut.apply`), and the cut only truncates the already balanced mix, so gains measured on the discarded countdown tail (up to 120 s) stay in the kept mix. After a successful cut, when the recording was balanced and both track files exist, rebuild the mix from the cut tracks with `AudioMixer.mix(..., micDelay: recording.micDelay, levelBalance: true)` into a staged temp file renamed over `mixPath` (the swap pattern `RecordingCut` already uses). `WatchLoop` holds the recorder only as `any RecordingProvider`, so carry whether the mix was balanced on the result (for example a field on `RecordingResult` set by `buildRecording`) rather than asking the recorder. A failed rebuild keeps the cut, unbalanced-after-cut mix and logs it, like a failed cut keeps the uncut recording. Test: a capture whose discarded tail carries microphone speech far louder than the kept own voice yields a mix within 6 dB after the cut; the single-track and flag-off cuts are unchanged.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Tests/SilentTrackWatchdogSettingTests.swift` — default, persistence and toggle write-back pattern
- `app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift:22-60` and `:241-272` — `FakeCaptureSession`, recorder- and controller-level wiring tests
- `app/MeetingTranscriber/Tests/BuildRecordingNormalisationTests.swift:11-33` — `buildRecording` fixture pattern (raw float temp plus mic WAV)
- `app/MeetingTranscriber/Tests/DualSourceRecorderCrashRecoveryTests.swift:78-108` — crash-recovery fixture pattern (backdated tracks)
- `app/MeetingTranscriber/Tests/HelpBadgeTests.swift:223-245` and `:270-280` — help catalog and Audio-tab badge tests
- `app/MeetingTranscriber/Tests/PipelineControllerOutputFolderTests.swift:72-97` — building a `PipelineController` with an injected `QueueEnvironment` and a recording recovery closure

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/TestHelpers.swift:512` — `writeRawFloat32`
- `app/MeetingTranscriber/Tests/EchoCancellationSettingTests.swift` — second settings-test twin

### Key context
- `DualSourceRecorder.swift` has 577 lines and SwiftLint `--strict` fails at 600 (`file_length`). Keep the new doc comments short; if the file would still cross 600, first move `recoverCrashedRecording`, `recoverCrashedRecordings` and their private helpers unchanged into a new `DualSourceRecorder+CrashRecovery.swift` in its own commit, then make the behaviour change.
- `HelpBadgeTests.testAudioTabShowsHelpBadgesForNamedOptions` asserts exactly 6 badges on the Audio tab; the new toggle makes it 7. Update the count and its doc comment (a new option, not a weakened test), and add `SettingsHelp.levelBalance` to `testHelpCatalogStringsAreNonEmpty` and `testAudioTabWiresEachOptionsHelpText`.
- `FakeCaptureSession.stop()` reports no app track (`appAudioFileURL: nil`). For the recorder-level test give the fake an optional `appTrack: URL?`, write a 16 kHz mono raw float temp with `writeRawFloat32`, and stage the mic WAV the way the existing mic-only tests do.
- The new parameters default to `false` so the existing `buildRecording` and crash-recovery test calls keep today's output; production gets `true` only through the setting.
- Neither peer toggle (echo, watchdog) is in the `/ui/press` allowlist or the `/state` settings projection; add nothing there.
- Do not edit `CLAUDE.md` or `AGENTS.md`.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<your scratch dir>/home swift test --parallel --filter 'LevelBalance|BuildRecording|DualSourceRecorder|HelpBadge|SettingsInteraction|AudioMixer|StagedRecoveryFolder|PipelineController|AppState' > <your scratch dir>/t2.log 2>&1`, then read the log file (literal paths, no pipes).
- `./scripts/pre-push.sh --with-appstore` (release build, App Store variant included).
- Lint with the pinned tools as in task .1.
## Acceptance
- [ ] `LevelBalanceSettingTests`: on by default, survives a fresh `AppSettings` on the same defaults, and the toggle found by `A11yID.levelBalanceToggle` writes back (R5).
- [ ] `BuildRecordingLevelBalanceTests`: with `levelBalance: true` a quiet-mic plus loud-app fixture produces a `_mix.wav` whose two sides are within 6 dB (R1); `_app.wav` and `_mic.wav` are byte-identical to a run with `false` (R3); with `false` the mix is sample-identical to today's (R5).
- [ ] Recorder-level test: `stop()` hands `levelBalanceEnabled` through to the mix. Controller-level test: the setting, true and false, reaches a recording `WatchingController` starts.
- [ ] Crash recovery balances the rebuilt mix with the flag true and leaves it as today with false. `PipelineControllerLevelBalanceTests`: a controller built with an injected `QueueEnvironment` hands its `settings.levelBalanceEnabled` (true and false) to the staged-recording recovery callback when it builds a queue; `StagedRecoveryFolderTests` still proves the production callback works in the injected staging folder.
- [ ] `HelpBadgeTests` updated and green; `./scripts/pre-push.sh --with-appstore` passes; `./scripts/lint.sh` passes with the pinned tools.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
