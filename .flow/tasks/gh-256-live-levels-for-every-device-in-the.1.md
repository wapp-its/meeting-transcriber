---
satisfies: [R1]
---
# gh-256-live-levels-for-every-device-in-the.1 Meter one device's level in AudioTapLib (input IOProc, output tap)

## Description
The Core Audio layer, in AudioTapLib: open a level meter on one microphone (an IOProc on the device) or on one output (a device-stream tap that excludes this process, read through its own private aggregate), read its level, close it. No owner, no lane, no UI: those are .4 to .6. This is the early proof point (spec "Early proof point"), so it runs first and measures parked unknowns 1 and 4 on the build Mac (spec Architecture, Inputs and Outputs; A1, A2, A3).

**Size:** M
**Files:** `tools/audiotap/Sources/DeviceLevelMeter.swift` (new), `tools/audiotap/Sources/DeviceLevelMeter+Output.swift` (new), a lock-free level cell in C (new files in `tools/audiotap/Sources/CExceptionCatcher/` or a new small C target), `tools/audiotap/Package.swift` (only for a new C target), `tools/audiotap/Tests/DeviceLevelMeterTests.swift` (new). The rows for the new files in `docs/architecture-macos.md` are written by .6, so the first wave shares no file.
**Touches:** [tools/audiotap/Sources/DeviceLevelMeter*.swift, tools/audiotap/Sources/CExceptionCatcher/**, tools/audiotap/Sources/CLevelCell/**, tools/audiotap/Package.swift, tools/audiotap/Tests/DeviceLevelMeterTests.swift]

### Approach
- One public type (suggested `DeviceLevelMeter`) with `openInput(uid:shouldContinue:)`, `openOutput(uid:excludingPID:shouldContinue:)`, `levelDBFS()` and an idempotent `close()`. A failed open throws an error that carries the step (translate UID, own process object, create tap, create aggregate, create IOProc, start) and its `OSStatus`, so .4 can show "Can't read" and log the code (A14). Keep a failure distinct from an absence (project memory, "Core Audio PID translation folded a failed call into 'no process object'").
- `shouldContinue` is checked right before every step that starts hardware (creating the tap, creating the aggregate, `AudioDeviceStart`); when it returns false the open tears down what it built and starts nothing (spec Architecture, the capture gate; .4 passes "generation still current").
- **Input:** UID to device via `kAudioHardwarePropertyTranslateUIDToDevice`, `AudioDeviceCreateIOProcIDWithBlock` with a nil queue on the device, `AudioDeviceStart`. The block computes the buffer's RMS over all channels as dBFS (floor -120, as `DebugRMSReporter`) and stores it with the mach tick in a lock-free cell; no allocation, lock or log in the block (spec Architecture, Inputs). `LevelPublisher` locks and is fine only off the real-time thread, so it is not reused here; a C11 `stdatomic.h` relaxed store and load (two `uint64_t`, the level bits and the tick) needs no new package dependency.
- **Output:** the device-stream `CATapDescription` initialiser that excludes processes (check the exact name in the SDK's `CATapDescription.h`), private, this process's object excluded (`AppAudioCapture+PIDTranslation`), the device's UID, stream 0. Aggregate from `AppAudioCapture.aggregateDescription(nameTag:outputUID:tapUUID:)`, tap buffer from `AppAudioCapture.tapBuffer(in:)` (both internal to AudioTapLib, so the meter lives in the same module). Teardown order as `AppTapSession`: stop, destroy IOProc, destroy aggregate, destroy tap.
- **Reading:** `levelDBFS` decays to -120 after 0.5 s without a buffer, the rule of `currentLevel(level:lastUpdateTicks:nowTicks:stalenessSec:)` in `CurrentLevel.swift`. This is what makes a dormant tap-auto-start aggregate (nothing playing) read silent, and a device that goes quiet light nothing within one second (R1). The cell has no lock, so the callback can store a tick newer than a clock the reader sampled earlier, and `currentLevel` subtracts the two as `UInt64` with no guard (`CurrentLevel.swift:18`), which traps. So the reader loads the cell first and samples the clock after it, and a stored tick newer than the clock reads as fresh; `levelDBFS` takes no caller-supplied clock in production (a test seam may inject one).
- **Measure on the build Mac** with a small live check (an XCTest skipped unless an environment variable is set, or a throwaway harness not committed): parked unknown 1 (does an aggregate with the tap alone, no sub-device, deliver buffers? if yes, use it, so metering a headset's output does not run its microphone) and parked unknown 4 (does `AVCaptureDevice` discovery list the meter's aggregate?). Move each answer into the spec section that owns it (Architecture, Outputs; R7) and delete the parked bullet.

### Investigation targets
**Required** (read before coding):
- `tools/audiotap/Sources/AppAudioCapture.swift:360-440` — tap creation, aggregate creation, IOProc
- `tools/audiotap/Sources/AppAudioCapture+AggregateDescription.swift:20-41` — the aggregate description to reuse
- `tools/audiotap/Sources/AppAudioCapture+TapBuffer.swift:33-60` — the last buffer is the tap's (#803)
- `tools/audiotap/Sources/CurrentLevel.swift` and `tools/audiotap/Sources/LevelPublisher.swift` — staleness decay, and why the meter cannot use the lock

**Optional** (reference as needed):
- `tools/audiotap/Sources/DebugRMSReporter.swift:34-40` — RMS to dBFS
- `tools/audiotap/Tests/AppTapSessionTests.swift` — teardown tests
- `tools/audiotap/Sources/AppAudioCapture+PIDTranslation.swift` — this process's object

### Key context
- AudioTapLib builds with all warnings as errors and `ExistentialAny`; `AppAudioCapture.swift` is at 594 lines under SwiftLint's `--strict` 600-line limit, so nothing is added to it.
- A tap is created without error and delivers silence when the Audio Recording grant and Screen Recording are both missing (issue #524); the live check needs the grant the installed app has.
## Acceptance
- [ ] Unit tests without hardware: RMS to dBFS over a multi-channel buffer list, the -120 floor for silence; the level decays to -120 after 0.5 s without a buffer; a stored tick newer than the reader's clock reads as fresh and does not trap; each open step's failure maps to an error naming the step and its status; `shouldContinue` false before a start step starts nothing and tears down what was built; `close()` twice is safe.
- [ ] Live on the build Mac: an input meter on the built-in microphone moves with sound; an output meter on the default output moves while another process plays and reads -120 while nothing plays; after close, the system device list holds no meter aggregate and no tap is left. Results recorded in the done summary, or "blocked from verification" with the reason.
- [ ] Parked unknowns 1 and 4 answered from the measurement and moved into the spec.
- [ ] `tools/audiotap` tests green; `./scripts/lint.sh` clean with the pinned tools.
## Done summary
EARLY PROOF:

Both conditions the dispatch asked to flag first are true:
- (c) An output level on an output that is not the default cannot be read without running that device's input, when the device has one. The only aggregate shape that delivers audio there (tapped device as sub-device) runs the input; the shape without the sub-device delivers only zeros. Measured.
- (d) macOS shows a second indicator besides the microphone one: Control Center's "System Audio Recording" attribution ("aud") is active whenever an output meter's tap delivers, that is while something plays to a metered output. Measured.

(a) Input meter, IOProc on the device: delivers a live level. Measured.
- Built-in microphone: live, varying room level (quiet: median -47.6, max -35.2 dBFS; 13 of 15 samples above -60 dBFS, 2 at the floor while the device started). A low-volume system sound played to the speakers did not rise above room level, so "moves with a deliberate sound" is not shown on the built-in microphone at the allowed volume.
- The same code on a virtual loopback input followed a controlled 0.1 sine exactly: -120, then median -23.1 (expected -23.0), then -120 again.
- About 94 callbacks a second, 512 frames each.

(b) Output meter, device-stream tap excluding this process, read through a private aggregate. Measured.
- Tap alone in the aggregate: the default output delivered while a sound played (max -33.9) and stayed dormant with no callbacks while nothing played. An output that was not the default (a virtual device with one input and one output) gave callbacks but only zeros, in three variants: with drift compensation, without it, and with the main sub-device key but no sub-device list.
- Tapped device as sub-device (the recording's description, kept): delivered on both, default -34.0, virtual -22.9.
- Production code, default output: -120 for 15 of 15 samples while nothing played; max -34.1 while a sound played; -120 for 10 of 10 samples one second after and the second after.
- Production code, virtual output: median -23.1 while the tone played, -120 while idle.

(c) Output device that also has an input. Measured.
- Sub-device shape: each callback carries two buffers (the device's input, then the tap); while sound plays to that output this process lists the device among its input devices, and coreaudiod requests the Microphone grant at the open and when the aggregate wakes. While nothing plays the aggregate is dormant and runs no input.
- Tap-only shape: one buffer, no input device, but zeros on a non-default output (see b).
- Disabling the input stream through the IOProc's stream usage gives a null input buffer, but the device stays listed as an input device of this process.
- The input scope's stream "is active" property read 1 in every state, so it tells nothing.
- This process's running-input flag reads 1 whenever any output tap delivers, in both shapes, also with no input device listed.

(d) Prompts and indicators, from the TCC and Control Center logs. Measured.
- No prompt was shown: zero prompting lines; every request was answered allowed, because the test host already held the grants.
- Microphone (kTCCServiceMicrophone): requests from coreaudiod at each input meter's open, and at the in/out output meter's open and wake.
- Audio Capture (kTCCServiceAudioCapture): one request from coreaudiod per tap.
- Screen Capture (kTCCServiceScreenCapture): preflight checks only.
- Control Center sensor indicators: "mic" for input meters; "aud" (System Audio Recording) while an output tap delivers, none while it is dormant; both for the in/out output meter while it plays.
- Inferred, not measured: on a Mac where the app lacks the Audio Recording grant, the first output meter would make macOS ask for it.

(e) After close. Measured.
- Device and tap lists were back to baseline within 22 to 25 ms in every case, including four meters open at once (closing all four took 79 ms).
- An open cancelled before the tap built nothing (1 ms). An unknown UID gave deviceNotFound.

Summary: AudioTapLib can now open a live level meter on one device: an input through an IOProc on the device, an output through a private device-stream tap and aggregate. Each meter keeps its level in a lock-free C cell, decays to -120 half a second after the last buffer, names the failed step and status, honours shouldContinue before every start step and closes idempotently.

Live acceptance on the build Mac (macOS 26.6):
- Input meter on the built-in microphone moves: live varying room level. With a deliberate sound only on a loopback input (see a).
- Output meter on the default output moves while another process plays (max -34.1) and reads -120 while nothing plays. Measured.
- After close no meter aggregate or tap is left. Measured.

Parked unknowns 1 and 4, answered and moved into the spec's Architecture:
- 1: a device tap's aggregate needs the tapped device as sub-device; on an output with an input the meter runs that input while sound plays.
- 4: AVCaptureDevice discovery lists each meter aggregate as a microphone named "audiotap-level" and posts one connect and one disconnect notice. So the microphone list needs its own filter, and its refresh follows R8.
- The parked bullet on the system-audio recording indicator is answered by (d) above. It belongs to Validation step 6, so it stays in place for that task.

Assumptions (for the conductor to record):
- Sub-device aggregate shape kept: the tap-only shape is silent on non-default outputs. Flip point: if a later macOS delivers tap-only audio for non-default outputs, switch to stop running headset microphones. Test: the shape probe in (b).
- OpenError has three cases: deviceNotFound (an absence), cancelled(before:) and failed(step, status).
- A process with no Core Audio object excludes nothing; a failed lookup is a failure.
- The cell uses relaxed atomics: a reader may pair one buffer's level with the next buffer's tick. Both are fresh.
- The C target carries -Werror=function-effects as an unsafe flag (legal because the app uses the package by path). It makes a blocking call in the two real-time functions a build error.
- The Continuity microphone was not opened, so as not to wake another device.

Findings for later tasks:
- Open times: usually 30 to 95 ms. The first output opens after idle took 0.6 to 2 s, one early IOProc creation about 5 s, and the first AVCapture discovery 20 s. Relevant to task .4's two-second deadline.
- Close: usually 4 to 14 ms; the first output closes about 200 ms.
- An input meter on a device that also has outputs runs that device's output in this process too.
- This process's running-input flag reads 1 while any output meter delivers. Any check that reads this app's own running-input state must not take an open Audio Devices window for microphone use.

Verification:
- Quick command `cd tools/audiotap && swift build --build-tests -j 2 && swift test -j 2 --filter 'DeviceLevelMeter|AggregateDescription|CurrentLevel'`: green, 9 meter tests.
- Full AudioTapLib suite (`swift test -j 2`): 717 tests, 0 failures.
- `./scripts/lint.sh` with the pinned tools: 0 violations.
- The app package builds against the new C target.
- Mutation checks: dropping the newer-tick guard traps the fresh-tick test; reading only the first buffer of either kind fails the RMS tests.
- Test and code share one commit: the tests do not compile without the new types.
- baseline: green (CurrentLevel and AggregateDescription filter, lint); pending (DeviceLevelMeter filter: this task creates its test file)

stage: impl-review - ran [2026-11-16T13:54Z..2026-11-16T14:00Z]
Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: b43649709d0c0b7312de771019bf7d5df5fc66eb, 091aaaabce8160d4f81065d3942a71bd68a4f946
- Tests: cd tools/audiotap && swift build --build-tests -j 2 && swift test -j 2 --filter 'DeviceLevelMeter|AggregateDescription|CurrentLevel', cd tools/audiotap && swift test -j 2 (717 tests, 0 failures), ./scripts/lint.sh (pinned SwiftFormat 0.63.0, SwiftLint 0.65.1), cd app/MeetingTranscriber && swift build -j 6
- PRs: