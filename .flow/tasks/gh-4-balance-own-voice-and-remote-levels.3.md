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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
