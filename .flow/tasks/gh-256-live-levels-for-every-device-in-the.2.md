---
satisfies: [R6, R11, R12]
---
# gh-256-live-levels-for-every-device-in-the.2 Level column, texts, In use and /state shape in the window state

## Description
The pure state value and the `/state` shape for live levels: each row's level column (`live`, `recorded`, `paused`, `cannotRead`, `noPermission`, `unknown`, `none`), the accepted texts and footers, the output hint line, "In use" from other processes on a metered device, and the snapshot's `visible`, `meters` and per-row `level`. No meter exists yet: the meters' results are an input value, so every arm is tested without hardware (spec API Contracts; R6, R11, R12; D6 to D8, A7, A12, A13).

**Size:** M
**Files:** `Sources/AudioDevicesWindowState.swift`, `Sources/AudioDevicesWindowState+Levels.swift` (new, only if the state file would pass about 400 lines), `Sources/AudioDeviceStatusProbe.swift`, `Sources/AudioDevicesWindowSnapshot.swift`, `Tests/AudioDevicesWindowStateTests.swift`, `Tests/AudioDevicesRPCTests.swift`, plus the probe's existing tests wherever they live (check `Tests/AudioDevicesWindowReaderTests.swift`)
**Touches:** [app/MeetingTranscriber/Sources/AudioDevicesWindowState*.swift, app/MeetingTranscriber/Sources/AudioDeviceStatusProbe.swift, app/MeetingTranscriber/Sources/AudioDevicesWindowSnapshot.swift, app/MeetingTranscriber/Tests/AudioDevicesWindowStateTests.swift, app/MeetingTranscriber/Tests/AudioDevicesRPCTests.swift, app/MeetingTranscriber/Tests/AudioDevicesWindowReaderTests.swift]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first: the state value is pure.
1. **Meters input** (suggested `AudioDevicesWindowState.Meters`): run state `off`, `running` or `paused(reason)` with reason `recording` or `call`; per device UID a result `opening`, `live(dBFS)`, `cannotRead(status)`, `noPermission` or `overdue`; the counts `openInputs`, `openOutputs`, `overdue`; whether a call signal is on; whether the output grant hint applies (Screen Recording not healthy, A12). Default `off`.
2. **Level column** (D6, D7, A13; R1, R2): while `running`, every connected row shows a bar from its meter (`litSegments(dBFS:)`, `Sources/AudioDevicesWindowState.swift:138`); `opening` shows an unlit bar; `overdue` shows "Unknown"; `cannotRead` "Can't read"; `noPermission` "No permission". While `paused`, the recorded microphone's row and the Meeting audio row keep gh-150's bars and every other row shows "Paused for call", or "Paused for recording" during a recording with no app tapped and no call signal. A configured microphone that is not connected keeps "no level". The level column shows whenever meters run or a recording runs (`showsLevelColumn`, `:130`).
3. **Footers and hints:** D8's two footers and A13's call-without-recording footer replace gh-150's footers (`:100-105`); the A12 line joins the Outputs section's hint lines, after the routing hint when both show. The Meeting audio group shows only during a recording, as today.
4. **In use on a metered device** (R6, A7): `AudioDeviceStatusProbe.read` takes the set of metered UIDs; for those devices "In use" comes from the process objects of every process except this one that runs audio and lists the device in `kAudioProcessPropertyDevices` (input or output scope), an aggregate such a process uses counting for its active sub-devices; a failed read yields "Status unknown". Unmetered devices keep the running flag. Reuse `RawReads.objectIDs` and `processObject` with their `Reading` results.
5. **Snapshot** (R11): `visible`, `meters { state, pauseReason, openInputs, openOutputs, overdue }`, a `level` per row and `selfRunningInput` as API Contracts write them, built from the state value with no Core Audio call; the closed form `open: false, visible: false, meters.state: "off", rows: []`.

### Investigation targets
**Required** (read before coding):
- `Sources/AudioDevicesWindowState.swift:13-276` — rows, marks, footers, the A9 mapping
- `Sources/AudioDeviceStatusProbe.swift:27-103` — running flag, own PID, process-object reads
- `Sources/AudioDevicesWindowSnapshot.swift:12-85` — the `/state` encoding (`#if !APPSTORE`)
- `Tests/AudioDevicesWindowStateTests.swift` — pure-state test style

**Optional** (reference as needed):
- `Tests/AudioDevicesRPCTests.swift:89-154` — `/state` while a read hangs, JSON shape
- `Sources/MeetingMicrophoneProbe.swift:27-90` — process-object reads

### Key context
- gh-150's tests that assert "no level" on idle rows and the old footers change meaning; rewrite them to the accepted texts and say so in the commit body (a changed requirement, not a weakened test).
- The snapshot type exists only in the Homebrew variant; the state value builds in both.

## Acceptance
- [ ] State tests, written first and seen failing: every level arm (running, opening, paused for call, paused for recording, can't read, no permission, unknown, not connected), recorded bars and the Meeting audio group during a recording, D8's and A13's footers word for word, the A12 line only while Screen Recording is not healthy.
- [ ] Probe tests: on a metered device "In use" only from another process's devices (this process ignored), an aggregate counted for its active sub-devices, a failed read gives "Status unknown"; an unmetered device keeps the running flag.
- [ ] Snapshot test: the JSON shape of API Contracts, including the closed form, built with the fake reads untouched.
- [ ] Quick commands green; `./scripts/lint.sh` clean with the pinned tools.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
