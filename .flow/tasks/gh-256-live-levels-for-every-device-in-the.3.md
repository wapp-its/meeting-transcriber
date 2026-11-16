---
satisfies: [R5, R7, R8, R13]
---
# gh-256-live-levels-for-every-device-in-the.3 Detection skips this app's process; output list refresh off the main thread

## Description
Two changes that make the meters safe before any meter runs in the app: detection never claims this app's own process (R5, A8), and the output list refresh that a device notice starts reads off the main thread with a deadline, folding notices that arrive meanwhile (spec Architecture, "The device lists ignore the meters' own objects"; R7, R8). Both keep today's behaviour for users; they matter once every meter aggregate fires a device notice.

**Size:** M
**Files:** `Sources/MicInputDetector.swift`, `Sources/OutputDeviceController.swift`, `Tests/MicInputDetectorTests.swift`, `Tests/OutputDeviceControllerTests.swift`, `docs/architecture/detection.md` (the `OutputDeviceController` row in `docs/architecture-macos.md` is updated by .6)
**Touches:** [app/MeetingTranscriber/Sources/MicInputDetector.swift, app/MeetingTranscriber/Sources/OutputDeviceController.swift, app/MeetingTranscriber/Tests/MicInputDetectorTests.swift, app/MeetingTranscriber/Tests/OutputDeviceControllerTests.swift, docs/architecture/detection.md]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first for both.
1. **Own process** (R5): `MicInputDetector.claim(_:)` (`Sources/MicInputDetector.swift:378`) returns nil first when the snapshot's pid is this process's (`ProcessInfo.processInfo.processIdentifier`), before any pattern is matched. `claim` is the rule detection and `signallingMeetings()` share (`signallingHits`, `:330-345`), so one guard covers both. The file is at 591 of the 600 lines SwiftLint `--strict` allows: keep it to one or two lines.
2. **Off-main list refresh** (R8): `outputChanged()` (`Sources/OutputDeviceController.swift:114`) no longer calls `refresh()` synchronously. It starts one read of the existing `listDevices` and `readDefault` seams on a serial queue with a two-second deadline, in the reader's pattern (`Sources/AudioDevicesWindowReader.swift:51-65` for the in-flight record, `:196-230` for dispatch and adoption). A notice while a read is out marks one follow-up read. The result is adopted on the main actor only if its deadline has not passed (checked again at adoption, project memory "A deadline checked only by the polling tick lets an overdue result through"), assigned only on a change, and then `evaluate(trigger: .outputChange)` runs as today. An overdue read logs one line with no device names and is dropped; the next notice or the follow-up reads again.
3. The init's, `select`'s and `recordingStarted`'s direct `refresh()` calls stay synchronous: they are not driven by notices.

### Investigation targets
**Required** (read before coding):
- `Sources/MicInputDetector.swift:241-245, 300-400` — snapshots, `signallingHits`, `claim`
- `Sources/OutputDeviceController.swift:40-120` — seams, `refresh`, `outputChanged`, `evaluate`
- `Sources/AudioDevicesWindowReader.swift:51-65, 170-230` — off-main read with deadline and adoption
- `Tests/OutputDeviceControllerTests.swift` — the `observeChanges` fake

**Optional** (reference as needed):
- `Tests/MicInputDetectorTests.swift` — injected `processProvider`
- `docs/architecture/detection.md:10` — the `MicInputDetector` bullet to extend

### Key context
- `OutputDevices.observeChanges` delivers on the main queue (`Sources/OutputDevices.swift:65-80`); the handler itself stays there, only the read moves.
- A test that checks "no Core Audio read on the main thread" records `Thread.isMainThread` inside the injected `listDevices` fake.
## Acceptance
- [ ] Detector tests, written first and seen failing: a snapshot carrying this process's pid running input is never claimed, by detection or by `signallingMeetings()`, with and without an added watched app whose bundle ID equals or prefixes this app's; other processes are claimed as before.
- [ ] Output controller tests, written first and seen failing: a device notice runs no list read on the main thread; a notice while the injected read is blocked leaves the main actor free and folds further notices into one follow-up read; a result past its deadline is not adopted; an unchanged list assigns nothing; the routing warning still fires after a changed default output.
- [ ] `docs/architecture/detection.md` states that detection never claims this app's own process.
- [ ] Quick commands green; `./scripts/lint.sh` clean with the pinned tools.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
