---
satisfies: [R1, R7, R8, R9]
---
# gh-256-live-levels-for-every-device-in-the.4 Meter set: one meter per listed device on one serial lane

## Description
The app-side owner of the meters (suggested `DeviceLevelMeters`, main actor): given the filtered microphone and output lists, the microphone permission and an "active" flag, it opens one meter per listed device through an injected device layer on one serial lane, keeps each device's result and level, and closes them all when deactivated. When it is active is .5's job (visibility, pause, gate); this task takes "active" as an input (spec Architecture, "One owner of the window's meters" and "Off the main thread, one at a time"; R1, R7, R8, R9; A10, A11, A14).

**Size:** M
**Files:** `Sources/DeviceLevelMeters.swift` (new), `Sources/DeviceLevelMeters+Lane.swift` (new), `Sources/MicrophoneDevices.swift` and `Sources/MicrophoneController.swift` (only if .1 found the meter aggregate in `AVCaptureDevice` discovery), `Tests/DeviceLevelMetersTests.swift` (new); the rows for the new files in `docs/architecture-macos.md` are written by .6
**Touches:** [app/MeetingTranscriber/Sources/DeviceLevelMeters*.swift, app/MeetingTranscriber/Sources/MicrophoneDevices.swift, app/MeetingTranscriber/Sources/MicrophoneController.swift, app/MeetingTranscriber/Tests/DeviceLevelMetersTests.swift, app/MeetingTranscriber/Tests/MicrophoneControllerTests.swift]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first, with a fake device layer that can block, fail with a status or report no permission.
1. **Seam:** a `Sendable` protocol over .1's open, level and close (suggested `DeviceMeterOpening`), a production adapter over `DeviceLevelMeter`, and the fake.
2. **Lane** (R8, A11): one serial queue. Every call carries the meters' generation and counts as outstanding from the moment it is queued until it returns (project memory, "Async probe result adopted after its precondition lapsed": count work at dispatch). Each has a two-second deadline, checked by the tick and again when the result is adopted. An overdue call marks its device `overdue` and is counted until it returns; while one is overdue no further call is queued, and the set reconciles once it returns. A returned open whose generation is stale, whose device is no longer listed or whose set was deactivated is closed at once. Opens pass `shouldContinue = { generation is still current }` into .1. Expose `hasOpenOrOutstanding` and a way to await it for .5's gate.
3. **Rebuild** (R7, R9): only when the filtered UID lists change: open the added devices, close the removed ones; a default change opens and closes nothing; a device removed while its open is out is closed when the open returns.
4. **Failures** (A10): a failed open gives `cannotRead(status)` and is retried only at the next list change or the next activation (the first activation after a pause counts). Microphone permission denied: inputs report `noPermission` and none opens; not yet asked: open, and macOS asks.
5. **Levels:** `level(uid)` reads .1's cell on the main actor without any Core Audio call, for the reader's 100 ms tick.
6. **Log** (A14): one line when the meters start and one when they stop, with counts, the pause reason (.5 passes it) and failed opens' status codes; never a device name or UID.
7. **Microphone list** (parked unknown 4, answered in .1): if the meter aggregate shows in `AVCaptureDevice` discovery, filter it from `MicrophoneDevices.available()` and move `MicrophoneController`'s notice-driven refresh off the main thread as .3 does for outputs (spec Architecture, last sentence of "The device lists ignore the meters' own objects"); otherwise record that nothing was needed.

### Investigation targets
**Required** (read before coding):
- `Sources/AudioDevicesWindowReader.swift:30-235` — lane, in-flight record, deadline, adoption
- `Tests/AudioDevicesWindowReaderTests.swift` — the blocking fake (semaphore) and injected clock
- `tools/audiotap/Sources/RestartArbiter.swift:27-60, 190-230` — generation-tagged attempts
- `Sources/MicrophoneController.swift:90-190` — the device list and its notices

**Optional** (reference as needed):
- `Sources/OutputDeviceController.swift` — the output list the meters follow
- `Sources/Permissions.swift:81` — microphone authorization status

### Key context
- Opening an input turns on the orange microphone indicator and can switch a Bluetooth headset's profile; tests never touch hardware.
- Keep meter work off the main actor entirely; the main actor only adopts results and reads cells.
## Acceptance
- [ ] Tests with the fake layer, written first and seen failing: activating opens one meter per listed device and deactivating closes all within one tick; a list notice with unchanged UIDs opens and closes nothing; an added device opens, a removed one closes, one removed while its open is out closes when it returns; a failed open reads "can't read" and is retried only at a list change or the next activation; microphone permission denied opens no input; a hung open keeps the state current, counts as overdue and queues nothing behind it; an open whose generation went stale starts nothing; the open input and output counts are exact.
- [ ] The start and stop log lines carry counts and status codes and no device name or UID (asserted on the formatted line).
- [ ] Parked unknown 4's consequence handled as in Approach 7, or recorded as not needed.
- [ ] Quick commands green; `./scripts/lint.sh` clean with the pinned tools.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
