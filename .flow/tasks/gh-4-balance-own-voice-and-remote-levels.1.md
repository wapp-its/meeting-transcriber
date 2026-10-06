---
satisfies: [R1, R2, R3, R6]
---
# gh-4-balance-own-voice-and-remote-levels.1 Speech-level balance in the mixer

## Description
Build the pure `LevelBalance` type (spec §Architecture: estimate, gain, clip budget, outcome) and wire it into `AudioMixer.mix` behind a new `levelBalance: Bool = false` parameter (R1, R2, R3 gate part, R6). First because it proves the approach (spec §Early proof point); nothing in production passes the flag until task .2.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/LevelBalance.swift` (new), `app/MeetingTranscriber/Sources/AudioMixer.swift`, `app/MeetingTranscriber/Tests/LevelBalanceTests.swift` (new), `app/MeetingTranscriber/Tests/AudioMixerLevelBalanceTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/LevelBalance.swift, app/MeetingTranscriber/Sources/AudioMixer.swift, app/MeetingTranscriber/Tests/LevelBalanceTests.swift, app/MeetingTranscriber/Tests/AudioMixerLevelBalanceTests.swift]

### Approach
- Tests first, written from the spec's contract (§Architecture numbers, R1–R3, R6), run and seen failing before the type exists.
- `LevelBalance` as an `enum` namespace with one named constant per number in spec §Architecture (100 ms frame, −90 dBFS silence floor, −60 dBFS absolute floor, +10 dB noise margin, 10th-percentile noise floor, −20 dBFS target, +24 dB boost cap, 0.1 % clip budget, 5 s track and 0.5 s sample minimum speech) and an `Outcome` value type: speech level (nil = not measurable), applied gain in dB, and which limit lowered it (none, boost cap, clip budget). Suggested surface, final names are yours: a measuring function, an in-place `balance(_ samples: inout [Float], sampleRate:minimumSpeechSeconds:) -> Outcome`, and a formatter for the log line.
- Frames: consecutive 100 ms frames; a trailing partial frame is ignored for measuring only (the gain applies to every sample). Sort frame levels (at most 144 000 for 4 h), never samples.
- Clip budget without sorting samples: only a sample above 1/maxGain (−24 dBFS) can clip, so a histogram of the speech frames' |x| between −24 and 0 dBFS (for example 0.1 dB bins) yields the largest gain that keeps at most 0.1 % of speech-frame samples above full scale. Clamp every sample to ±1.0 after scaling.
- In `AudioMixer.mix` (`AudioMixer.swift:33-78`) add the parameter last with default `false`. When true: after the `suppressEcho` block (`:48-56`) and before delay alignment (`:58`), balance `appSamples` and the gated `micSamples` in place with the track minimum, then log once. When false, nothing in the function changes.
- Keep `mix`'s body under SwiftLint's 60-line `function_body_length` (lint runs `--strict`, so warnings fail): per-track work and log formatting live in `LevelBalance`.
- Log through the file's existing `logger` at `.notice` (kept by `log show`, unlike `.info`), numbers `privacy: .public`, for example `Level balance: app speech -18.4 dBFS gain -1.6 dB; mic speech -44.9 dBFS gain +24.0 dB (boost cap)`, or `mic not measurable, gain 0 dB`. No URL, file name or title in the line.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/AudioMixer.swift:33-168` — `mix`, `mixTracks`, `suppressEcho` and their order
- `app/MeetingTranscriber/Sources/AudioMixer.swift:345-357` — `rmsDecibels` (dB convention, 1e-10 floor)
- `app/MeetingTranscriber/Tests/AudioMixerDelayTests.swift:7-37` — WAV fixture pattern for `mix` tests
- `app/MeetingTranscriber/Tests/AudioMixerTests.swift:45-90` — `suppressEcho` test pattern

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/TestHelpers.swift:14` (`makeTempDirectory`), `:28` (`makeTempFile`)
- `app/MeetingTranscriber/Tests/Fixtures/two_speakers_en.wav`, `two_speakers_de.wav` — synthetic TTS speech, fine for one real-speech mixer test (not meeting recordings)

### Key context
- `mix` runs synchronously on the main actor inside `DualSourceRecorder.stop()` for recordings up to 4 h: keep the added work O(n) with no extra full-length copy. Plain Swift loops are the codebase convention (`mixTracks`, `suppressEcho`); Accelerate is not imported anywhere, either is acceptable.
- Test signals must be deterministic (a sine, or noise from a seeded generator; never unseeded `Float.random`). A sine of amplitude A has RMS A/√2, so derive amplitudes from the wanted dBFS. In the R1 test put app and mic bursts in alternating slots with gaps of at least 300 ms, so the gate's 200 ms hang never reaches a mic burst.
- Spec A5 is load-bearing, so test it: a mic track carrying a −30 dBFS copy of the app bursts at the same time (bleed) plus own-voice bursts at −44 dBFS while the app is silent must measure at about −44 dBFS, not the bleed's level.
- Existing `mix` callers (`DualSourceRecorder+BuildRecording.swift:193`, `PipelineQueue+Stages.swift:619`) and the tests that call it (`AudioMixerDelayTests`, `BuildRecordingNormalisationTests`, `MicDelayNormalisationTests`, `EchoBleedDetectorTests`) pass nothing and must keep byte-identical output; do not change them in this task.
- Do not edit `CLAUDE.md` or `AGENTS.md` (fork rule: they belong to the original project); the behaviour is documented in the doc comments of `LevelBalance` and `mix`.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<your scratch dir>/home swift test --parallel --filter 'LevelBalance|AudioMixer|MicDelayNormalisation|EchoBleedDetector|BuildRecording' > <your scratch dir>/t1.log 2>&1`, then read the log file. Never pipe a test run into tail, head or grep. Use literal paths: a shell hook blocks redirects to `$VAR` paths.
- Lint: the pinned SwiftFormat and SwiftLint are not installed globally. Fetch the release assets named in `scripts/tool-versions.sh`, check their SHA-256, unpack into a temp dir, then `PATH=<that dir>:$PATH ./scripts/lint.sh`. Do not brew-install.
## Acceptance
- [ ] `LevelBalanceTests`: the estimate is within 1 dB of known burst levels with speech filling 50 % of a 20 s track and 5 % of a 120 s track (6 s of speech, above the 5 s minimum); not measurable for digital zeros, steady −50 dBFS noise, a 60 s track holding only 3 s of speech, and a sample below the 0.5 s minimum; gain reaches −20 dBFS, stops at +24 dB with the boost-cap limit reported, and cuts are unbounded; the clip budget lowers a boost on a transient-heavy track (at most 0.1 % of speech-frame samples beyond full scale, clip-budget limit reported), including a 120 s track whose speech fills 5 %; when the budget binds, the applied gain is the largest one that keeps at most 0.1 % of speech-frame samples beyond full scale (within 0.1 dB) and never more; every sample is within ±1.0 after balancing.
- [ ] `AudioMixerLevelBalanceTests`: with `levelBalance: true`, −18 dBFS app bursts and −44 dBFS mic bursts land within 6 dB of each other in the mix (R1); with `false` the output equals `mixTracks` over the `suppressEcho`'d inputs sample for sample; the gated mic windows are zero at the same indices with the flag on and off (R3); the bleed test from Key context passes (A5); an all-zero mic track stays all zero while the app track is balanced; a transient-heavy mic track whose boost the clip budget limits is raised exactly to that limit, reports the clip budget, and stays below the target (R1's limit clause); no mix sample exceeds ±1.0 (R2).
- [ ] The log-line formatter is unit-tested: it carries both tracks' levels and gains, or "not measurable", and the limit that applied, and no path or title (R6).
- [ ] Existing `AudioMixer*`, `BuildRecording*`, `MicDelayNormalisation*` and `EchoBleedDetector*` tests pass unchanged.
- [ ] `./scripts/lint.sh` passes with the pinned tools.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
