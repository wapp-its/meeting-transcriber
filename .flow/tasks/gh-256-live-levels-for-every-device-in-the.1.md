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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
