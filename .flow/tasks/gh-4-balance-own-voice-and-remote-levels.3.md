---
satisfies: [R4]
---
# gh-4-balance-own-voice-and-remote-levels.3 Balanced voice samples in the naming dialog

## Description
Balance each naming-dialog voice sample before it plays (R4). Last because it uses `LevelBalance` from .1 and the setting from .2.

**Size:** S
**Files:** `app/MeetingTranscriber/Sources/SpeakerNamingView.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Tests/SpeakerSampleLevelTests.swift` (new); estimator noise reference (spec A10, added 2026-10-07 after impl-review round 1): `app/MeetingTranscriber/Sources/LevelBalance.swift`, `app/MeetingTranscriber/Tests/LevelBalanceTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/SpeakerNamingView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Tests/SpeakerSampleLevelTests.swift, app/MeetingTranscriber/Sources/LevelBalance.swift, app/MeetingTranscriber/Tests/LevelBalanceTests.swift]

### Approach
- `SpeakerNamingView`: add `let balanceSampleLevels: Bool` and an init parameter `balanceSampleLevels: Bool = false` (init at `SpeakerNamingView.swift:48-81`). The default keeps voice enrollment (`VoiceEnrollmentView.swift:118`) and every existing test as it is.
- Add a pure `nonisolated static func` in the "Pure Functions (testable without UI)" section (`:603`, beside `sampleRange` at `:611`) that takes the decoded samples, the range, the sample rate and the flag, and returns what to play: the cut, run through `LevelBalance.balance` with the 0.5 s sample minimum when the flag is on.
- `playSpeakerSnippet` (`:531-582`) calls it inside the detached task in place of `Array(samples[range])`; capture the flag as a value in the closure's capture list, as `source` already is.
- `MeetingTranscriberApp.speakerNamingForm` (`MeetingTranscriberApp.swift:335-355`) passes `balanceSampleLevels: appState.settings.levelBalanceEnabled`.
- Noise reference for short samples (spec A10, from impl-review round 1): a 1.5–2 s sample that is speech throughout has no pause, so `LevelBalance.measure`'s 10th-percentile noise floor lands inside the speech and the +10 dB margin excludes most frames; the sample reads as not measurable and plays unchanged (R4 broken). Give `LevelBalance.measure`/`balance` an optional noise reference (frame levels or samples of the whole track the cut comes from) whose 10th percentile replaces the sample's own floor when supplied; `playbackSnippet` passes the whole decoded file. Thresholds, the 0.5 s minimum, cap, clip budget and clamp are unchanged, and the track path (`AudioMixer.mix`, no reference) measures exactly as before. Tests: `LevelBalanceTests` gets an all-speech −40 dBFS 1.5 s sample that is unmeasurable alone and raised to −20 ± 1 dBFS with a reference carrying the track's −70 dBFS room tone; the existing estimator tests stay byte-identical.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/SpeakerNamingView.swift:531-620` — the playback path and the pure helpers
- `app/MeetingTranscriber/Tests/SampleRangeTests.swift` — test style for a pure helper of this view

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/SpeakerNamingData.swift:40-80` — `sampleSource`, which file a sample is cut from
- `app/MeetingTranscriber/Tests/SpeakerSampleTrackTests.swift`

### Key context
- Playback is best-effort and silent on failure today; keep it that way. The helper is pure and cannot throw.
- Pass the decoded file's own sample rate through: the track sidecars are 16 kHz, a mix fallback from an import may not be.
- The file carries `swiftlint:disable file_length` already; keep `playSpeakerSnippet`'s body short anyway (`function_body_length` 60 under `--strict`).

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<your scratch dir>/home swift test --parallel --filter 'SpeakerSampleLevel|SampleRange|SpeakerSampleTrack|SpeakerNamingView|AccidentalNamingAccept|SpeakerNamingFieldIdentity|SpeakerNamingRowWrites|LevelBalance' > <your scratch dir>/t3.log 2>&1`, then read the log file.
- Full suite once, at the end: `swift test --parallel > <your scratch dir>/full.log 2>&1` with the same `CFFIXED_USER_HOME`. Known environmental failures under a scratch home: model-download tests (Parakeet E2E, ModelPreload, LiveCaption, `WhisperKitLocalSnapshotTests.testProductionLocatesARealFetchedModel`) and the dark-mode flake in `MenuBarIconSnapshotTests.testStaticBadgeSnapshots`. Anything else red is this spec's.
- `./scripts/pre-push.sh --with-appstore`; lint with the pinned tools as in task .1.

## Acceptance
- [ ] `SpeakerSampleLevelTests` on the pure helper, flag on: a sample whose speech is at −40 dBFS comes out at −20 ± 1 dBFS, one at −8 dBFS is lowered to −20 ± 1 dBFS, a sample with under 0.5 s of speech comes back unchanged, and no output sample exceeds ±1.0. Flag off: the plain cut, sample for sample (R4).
- [ ] `MeetingTranscriberApp.speakerNamingForm` passes the setting; voice enrollment and the existing naming-view tests are unchanged.
- [ ] Focused tests pass; the full suite passes apart from the known environmental failures; `./scripts/pre-push.sh --with-appstore` and `./scripts/lint.sh` pass.


## Done summary
With the balance switch on, each voice sample the speaker-naming dialog plays is brought to the same -20 dBFS speech level as the mix, so a quiet own-voice sample and a loud far-end sample play at a similar loudness. That now includes a sample that is speech from start to end, which the first version left at its recorded level.

stage: impl-review - ran [2026-10-07T07:17Z..2026-10-07T07:33Z]

Tier: session (jev-unavailable(no_key)); project routing block pins implementer opus at xhigh (actual: claude-opus-5-5)

What changed:
- `SpeakerNamingView.playbackSnippet(of:range:sampleRate:balanced:)` (e5b80aca) is pure, nonisolated and cannot throw. It cuts the range and, with the flag, runs the cut through `LevelBalance.balance` with the 0.5 s sample minimum and the decoded file's own sample rate. `playSpeakerSnippet` calls it in the detached task with the flag captured by value. The view takes `balanceSampleLevels: Bool = false`, and `MeetingTranscriberApp.speakerNamingForm` passes `appState.settings.levelBalanceEnabled`. Voice enrollment and the existing naming-view tests keep the default (off).
- Noise reference (6670b324, spec A10). `LevelBalance.measure` and `balance` take `noiseReference: [Float] = []`. When it is non-empty, the noise floor is the 10th percentile of the reference's frames instead of the samples' own. `playbackSnippet` passes the whole decoded file. The -60 dBFS floor, the +10 dB margin, the minimums, the cap, the clip budget and the clamp are unchanged. `AudioMixer.mix` passes no reference, so a track measures exactly as before.

Review: codex gpt-5.6-sol at xhigh. The receipt `/tmp/impl-review-receipt-23a2c07fb458-gh-4-balance-own-voice-and-remote-levels.3.json` reads model gpt-5.6-sol, effort xhigh, verdict SHIP.
- Round 1 (07:17-07:19Z, one correctness draw) returned NEEDS_WORK with one P1 on R4, and the validator kept it. A sample that is speech throughout took its noise floor from its own speech, no frame cleared the margin, and the sample played unchanged (-40 dBFS stayed -40).
- Round 2 (07:31-07:33Z, single re-review resuming the round-1 session) reported the finding fixed and returned SHIP with no findings.
- Both rounds ran with CODEX_SANDBOX=workspace-write, the owner's standing setting, which overrides the skill's "never widen the sandbox" text. After round 2 `git status` showed only flowctl's review ledger. The reviewer left no files.

Baseline: green. Before any edit in this session the focused filter `SpeakerSampleLevel|SampleRange|SpeakerSampleTrack|SpeakerNamingView|AccidentalNamingAccept|SpeakerNamingFieldIdentity|SpeakerNamingRowWrites|LevelBalance|AudioMixer` ran 181 tests, exit 0.

Tests first: with the reference accepted but unused by the estimator, `LevelBalanceTests.testAnAllSpeechSampleIsMeasuredAgainstTheNoiseFloorOfItsTrack` read -40.0 dBFS against the -20 target. In `SpeakerSampleLevelTests.testWithTheFlagASampleIsBroughtToTheTargetSpeechLevel` the quiet row read -39.7 and the loud row read -8.0. Wiring the reference turned all three green.

Acceptance, test by test:
- R4, flag on: `SpeakerSampleLevelTests.testWithTheFlagASampleIsBroughtToTheTargetSpeechLevel` cuts a 1.5 s sample that is speech from start to end. The room tone sits only in the 1 s pauses around it, and contrasting speech fills the rest of the file. -40 dBFS comes out at -20 +/- 1 with 8 transients clamped at full scale, and -8 dBFS is lowered to -20 +/- 1. No output sample exceeds +/-1.0.
- R4, plain cut: `testThePlainCutPlaysWithTheFlagOffOrWithoutEnoughSpeech` returns the cut sample for sample with the flag off, and with the flag on for 0.4 s of speech at 16 kHz and at 48 kHz.
- R4 estimator (A10): `LevelBalanceTests.testAnAllSpeechSampleIsMeasuredAgainstTheNoiseFloorOfItsTrack`. A 1.5 s all-speech -40 dBFS cut is unmeasurable alone (gain 0, samples unchanged). Measured against its 10 s track with -70 dBFS room tone, it reaches -20 +/- 1.
- Track path unchanged: the existing `LevelBalanceTests` cases and `AudioMixerLevelBalanceTests` are byte-identical in the diff (18 lines added to `LevelBalanceTests`, none removed) and pass.
- Wiring: `MeetingTranscriberApp.speakerNamingForm` passes the setting. Voice enrollment and the existing naming-view tests are unchanged and green.

Mutation checks on the final code. Each turned the tests red, and each source was restored from a copy and the diff checked:
- `playbackSnippet` without the reference: both flag-on rows red (-39.7 and -8.0 dBFS).
- Balancing the whole file before cutting: both flag-on rows red (-50.8 and -12.7 dBFS), and the plain-cut rows red too.
- The previous worker's checks (the 5 s track minimum, a hard-coded 16 kHz rate) were not re-run here.

Verification on the committed tree (3966d893):
- Focused filter (as for the baseline): 182 tests, exit 0 (`/private/tmp/gh4/t3r2/green2.log`).
- `PATH=/private/tmp/gh4/tools:$PATH ./scripts/lint.sh` (SwiftFormat 0.63.0, SwiftLint 0.65.1): exit 0. 0 of 686 files need formatting, 0 violations.
- `./scripts/pre-push.sh --with-appstore`: exit 0. Release builds of the Homebrew and App Store variants completed.
- Full suite once, `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh4-home swift test --parallel`: 3691 tests ran, exit 1 with 13 failures, all on the known list of model downloads under a scratch home. Parakeet E2E (6): testDownloadProgressReachesOne, testParakeetModelLoadsSuccessfully, testTranscribeSegmentsGroupsIntoSentences, testTranscribeSegmentsProducesGermanContent, testTranscribeSegmentsWithFixture, testTranscriptionProgressReachesOne, each "model should be loaded". ModelPreload (1): testPreloadParakeet. LiveCaption (6): LiveCaptionPipelineTests testControllerFlushDeliversPendingAppChannelFinal, testControllerFlushDeliversPendingFinalToCaptions, testFlushAfterNaturalSpeechEndEmitsNoSecondFinal, testFlushCommitsPendingUtteranceContract, testFlushIsIdempotent, and LiveTranscriptionE2ETests testLivePipelineProducesFinalisedCaptionsAcrossChannels. Nothing outside that list failed. Log `/private/tmp/gh4/t3r2/full.log`.

Decisions:
- The reference is a `[Float]` with an empty default. SwiftLint's `discouraged_optional_collection` rejects `[Float]?`, and an empty-array default is how `WatchLoop` and `PowerAssertionDetector` handle the same case.
- A reference with no audible frame leaves the sample not measurable. That happens only when the file is all digital silence, and then the cut has no speech either.
- The sample tests now cut 1.5 s of speech with no pause of its own (was 3 s with a 1.5 s pause). The new cut is the shortest segment `selectSampleSegment` picks. The old cut carried its own pause and hid the defect.

Observation, not acted on: measuring a sample frames the whole decoded file again on each play. A one-hour 16 kHz track is one pass over 57.6 M samples in the detached task, after the decode that already reads the whole file.

Feature map: no user route changed.

Memory: captured bug/runtime-errors/short-all-speech-sample-read-as-2026-10-07 (NEEDS_WORK -> SHIP).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: e5b80aca8906a32f18862d853590160e067ba576, 4f79e04b0094b3f48cfe098b68541ba34e9f1b6f, 9fc6d81dcdd2dc1a886c9fad2e8ed1a0437acb5a, 6670b32485b71b677a89e53b8162cc4d8057085c, 3966d893e794703b23df02ff14228a11fedb8526
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh4-home swift test --parallel --filter 'SpeakerSampleLevel|SampleRange|SpeakerSampleTrack|SpeakerNamingView|AccidentalNamingAccept|SpeakerNamingFieldIdentity|SpeakerNamingRowWrites|LevelBalance|AudioMixer' -> exit 0, 182 tests (baseline: green, 181 tests pre-edit), PATH=/private/tmp/gh4/tools:$PATH ./scripts/lint.sh -> exit 0, 0 violations, 0/686 files need formatting, ./scripts/pre-push.sh --with-appstore -> exit 0 (Homebrew and App Store release builds), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh4-home swift test --parallel -> exit 1, 3691 tests, 13 failures all known environmental (Parakeet E2E x6, ModelPreload x1, LiveCaptionPipeline x5, LiveTranscriptionE2E x1)
- PRs: