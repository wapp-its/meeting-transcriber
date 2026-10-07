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
The balance switch is in Settings > Audio ("Balance my voice and the meeting audio", on by default) and reaches every place that writes a two-track mix: the recorder's `stop()` through the recorder factory, launch-time crash recovery through `PipelineController`'s staging-recovery callback, and now the cut-back path. A detected meeting that ends through the end-of-meeting question gets its mix made again from the kept tracks after the cut, so loud talk in the room during the countdown no longer sets the meeting's gains.

stage: impl-review - ran [2026-10-07T06:31Z..2026-10-07T07:00Z]

Tier: session (jev-unavailable(no_key)); project routing block pins implementer opus at xhigh (actual: claude-opus-5-5)

Review: codex gpt-5.6-sol at xhigh, receipt /tmp/impl-review-receipt-23a2c07fb458-gh-4-balance-own-voice-and-remote-levels.2.json (reads model gpt-5.6-sol, effort xhigh). Round 1 (06:31-06:41, three draws: correctness SHIP, contracts SHIP, integration NEEDS_WORK) kept one P1 on R1 after the validator pass: `stop()` balanced the whole capture and `WatchLoop.cutBack` -> `RecordingCut.apply` then only shortened the balanced mix, so gains measured on the discarded countdown tail stayed in the kept mix. The conductor widened the task to the cut-back files (spec A9). Fixed in 63be36d6. Round 2 (single re-review, 06:57-07:00) reported the prior finding fixed and returned SHIP with no findings. Both rounds ran with CODEX_SANDBOX=workspace-write as the dispatch asked (owner's standing setting; the skill's own text says never to set it, recorded here, not resolved); after each round `git status` showed only flowctl's review ledger, nothing the reviewer wrote.

Baseline: green before any edit in each session. Round 1: the task's focused filter ran 284 tests with 0 failures. Round 2 (on 25334b72): the focused filter plus `WatchLoopMeetingEnd|RecordingCut` ran 314 tests, exit 0.

Tests first. Round 1: with the tests written and no source change, the test build failed on the missing `levelBalanceEnabled`, `A11yID.levelBalanceToggle` and the new parameters. Round 2: with `RecordingResult.levelBalanced` and `RecordingCut.remixBalanced` in place but not called from `cutBack`, `WatchLoopMeetingEndTests.testACutBalancedMixIsMadeAgainFromTheKeptTracks` failed with a 33.1 dB gap between the two sides (limit 6); wiring the call turned it green.

Acceptance, test by test:
- Setting (R5): `LevelBalanceSettingTests` on by default, survives a fresh `AppSettings` on the same defaults, the toggle found by `A11yID.levelBalanceToggle` writes back, and it stays enabled in record-only mode.
- `buildRecording` (R1, R3, R5): `BuildRecordingLevelBalanceTests` has a -18/-44 dBFS fixture within 6 dB with the flag (and the result reports `levelBalanced`); `_app.wav` and `_mic.wav` byte-identical with the flag on and off (and the mixes differ); with the flag off the mix equals `mixTracks` over the `suppressEcho`'d track files (and the result reports not balanced).
- Recorder: `DualSourceRecorderLifecycleTests.testStopHandsTheLevelBalanceFlagToTheMix` (within 6 dB on, 26 dB apart as recorded off). Controller: `testTheLevelBalanceSettingReachesARecordingTheControllerStarts` (true and false, recorder seeded with the opposite).
- Crash recovery: `DualSourceRecorderCrashRecoveryTests.testRecoveryBalancesTheRebuiltMixOnlyWithTheFlag`; `PipelineControllerLevelBalanceTests` (settings true then false reach the callback per built queue); `StagedRecoveryFolderTests` still green with the two-argument callback.
- Cut-back path (R1, spec A9): `WatchLoopMeetingEndTests.testACutBalancedMixIsMadeAgainFromTheKeptTracks` drives `handleMeeting` through an unanswered question: 24 s of headset-gap meeting plus a 120 s tail with -10 dBFS microphone speech. The as-recorded mix is more than 6 dB apart (premise asserted); after the cut the mix is 24 s long and within 6 dB. `testAnUnbalancedOrSingleTrackMixIsOnlyCut`: a mix made without the balance and a single-track mix reported balanced come out as the first 24 s of the original, sample for sample.
- R1 error (balancing never stops the mix being written or the recording processed): `RecordingCutTests.testAFailedRemixLeavesTheMixAsItWas`: a remix whose swap fails leaves the mix byte-identical and no staged file behind; `cutBack` logs `recording_cut_remix_failed domain= code=` and returns the cut recording, so it is processed as before.
- `HelpBadgeTests`: Audio tab now 7 badges; `SettingsHelp.levelBalance` in the catalog and wiring tests.

Mutation checks. Round 1: dropping the factory line, passing `false` from `stop()`, passing `false` in batch recovery, handing a constant `true` from the controller, dimming the section in record-only mode, and passing `false` from `buildRecording` to the mix each turned their target test red. Round 2: remixing every cut whatever the flag turned `testAnUnbalancedOrSingleTrackMixIsOnlyCut` red; writing the remix straight onto the mix path turned `testAFailedRemixLeavesTheMixAsItWas` red; `buildRecording` never reporting the balance turned `testTheFlagBringsBothSidesOfTheMixWithinSixDecibels` red. The sources were restored from backups after each and the diff checked.

Verification on the committed tree (63be36d6):
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh4-home swift test --parallel --filter 'LevelBalance|BuildRecording|DualSourceRecorder|HelpBadge|SettingsInteraction|AudioMixer|StagedRecoveryFolder|PipelineController|AppState|WatchLoopMeetingEnd|RecordingCut'` exited 0 with 317 tests (314 before plus 3 new).
- `PATH=/private/tmp/gh4/tools:$PATH ./scripts/lint.sh` (SwiftFormat 0.63.0, SwiftLint 0.65.1) exited 0: 0 of 685 files need formatting, 0 violations.
- `./scripts/pre-push.sh --with-appstore` exited 0: release builds of the Homebrew and App Store variants completed.

Decisions:
- Whether a mix was balanced travels on `RecordingResult.levelBalanced`, set by `buildRecording` only for a two-track mix made with the flag, because `WatchLoop` holds the recorder only as `any RecordingProvider`. `RecordingCut.redirect` carries it too, so a recording pointed back at its uncut originals still describes its mix truthfully.
- The cut still shortens the mix first and the remix runs after it, so a failed remix leaves the cut (whole-capture balanced) mix and the recording is processed, the way a failed cut leaves the uncut recording. The remix writes a hidden `.<mix>.remixing.wav` sibling and renames it over the mix.
- The failed-remix error case is tested at `RecordingCut` level through the injectable rename; `cutBack` has no injection seam and gets none added for a test.
- `DualSourceRecorder.swift` ends at 591 lines, under the 600 cap, so the optional pure-move commit was not needed.
- The "not dimmed in record-only mode" constraint is pinned by a test instead of a comment.

Observations, not acted on:
- A cut-back balanced recording now gets two level-balance notice lines: the first from `stop()` over the whole capture, the second, after `recording_cut kept_s=`, for the mix that is saved. The second is the one that describes the file.
- The remix is a second full mix pass on the main actor right after `stop()`'s own, like the mix inside `stop()` itself; for an hour-long meeting that roughly doubles the stop's blocking time on the cut path.

Feature map: no user route changed; Settings > Audio gains a "Recording Levels" section.

Memory: captured bug/data/whole-capture-level-balance-kept-after-2026-10-07 (NEEDS_WORK -> SHIP).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 0fde5a46e206732a02695af01db3e224a781a357, 0a49acfd002cf8be7d1b822ba75a4dc1c7c7fd19, 25334b72d67d0e9eb7afbcdb7d6babd35fcd8fad, 63be36d6dd9ac50a711905b7eb43db1d186d167b
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh4-home swift test --parallel --filter 'LevelBalance|BuildRecording|DualSourceRecorder|HelpBadge|SettingsInteraction|AudioMixer|StagedRecoveryFolder|PipelineController|AppState|WatchLoopMeetingEnd|RecordingCut' -> exit 0, 317 tests, PATH=/private/tmp/gh4/tools:$PATH ./scripts/lint.sh -> exit 0, 0/685 files need formatting, 0 violations, ./scripts/pre-push.sh --with-appstore -> exit 0, Homebrew and App Store release builds
- PRs: