---
satisfies: [R5, R6]
---
# gh-43-microphone-in-the-menu-and-the-meeting.5 Meeting-app microphone probe and mismatch warning

## Description
App target. The measurement probe (R5) and the mismatch warning (R6): every 5 s during a recording that taps a meeting app and captures the microphone, read which input devices the tapped processes use, log it, decide match / mismatch / undetermined, and after two mismatching probes post one notification and show the hint in the menu's Microphone entry. Hardware reads, pure decisions and wiring are separate types so the decisions are tested without Core Audio.

**Size:** M
**Files:** new `app/MeetingTranscriber/Sources/MeetingMicrophoneProbe.swift`, new `app/MeetingTranscriber/Sources/MeetingMicrophoneVerdict.swift`, new `app/MeetingTranscriber/Sources/MeetingMicrophoneWarningPolicy.swift` (policy plus log-line builders), new `app/MeetingTranscriber/Sources/MicrophoneController+MeetingProbe.swift`, `app/MeetingTranscriber/Sources/MicrophoneController.swift` (injected dependencies, published hint), `app/MeetingTranscriber/Sources/AppState.swift` (pass notifier and verbose flag), `app/MeetingTranscriber/Sources/AppState+Microphone.swift` (hint into the menu state), new tests `MeetingMicrophoneVerdictTests.swift`, `MeetingMicrophoneWarningPolicyTests.swift`, `MicrophoneControllerMeetingProbeTests.swift`, `docs/architecture-macos.md`
**Touches:** [app/MeetingTranscriber/Sources/MeetingMicrophone*.swift, app/MeetingTranscriber/Sources/MicrophoneController*.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/AppState+Microphone.swift, app/MeetingTranscriber/Tests/MeetingMicrophone*.swift, app/MeetingTranscriber/Tests/MicrophoneControllerMeetingProbeTests.swift, docs/architecture-macos.md]

### Approach
- **Tests first** for the two pure types.
  - `MeetingMicrophoneVerdictTests`: match when any input device of an input-running process has the recorded UID (even beside an aggregate); mismatch when all devices are physical and none is recorded (names carried for the message); `noProcessCapturingInput` (none running input, or `isRunningInput` false everywhere); `unidentifiableDevice` for aggregate, virtual, unknown and an unlisted transport; `unreadableProperty` for a failed `isRunningInput`, device list, UID or transport read on an input-running process; `recordedMicrophoneUnknown` when the recorded UID is nil.
  - `MeetingMicrophoneWarningPolicyTests`: one mismatch → no notification; two consecutive → exactly one; a match or undetermined in between resets the count; never a second notification in the same recording; hint present only while the latest verdict is mismatch; first probe logs, an unchanged probe logs nothing, a change logs, the 21st change logs one "further changes not logged" line and then nothing; the stop line carries last verdict, probes, skipped probes, warned.
  - Log-line builders: exact wording per spec; no device name in any unconditional line; no UID in any line (build fixtures with distinctive UIDs and names and assert their absence); `?(<status>)` for failed reads.
- `MeetingMicrophoneProbe` (hardware side, no logic beyond reading): `struct MeetingInputProcess` (pid, executable name via AudioTapLib's public `getExecutableName(pid:)`, `isRunningInput: Reading<Bool>`, `inputDevices: Reading<[MeetingInputDevice]>`) and `struct MeetingInputDevice` (objectID, `uid: Reading<String>`, `name: Reading<String>`, `transport: Reading<UInt32>`), with a local `enum Reading<Value> { case value(Value), failed(OSStatus) }` shaped like `tools/audiotap/Sources/ProcessOutputState.swift:20-52`. Every read keeps its status, the name included: do **not** use AudioTapLib's `readCFStringAudioProperty`, which returns nil and drops the `OSStatus` (`tools/audiotap/Sources/Helpers.swift:107-121`); write a status-keeping CFString read. Put the four raw reads (PID translation, UInt32 property, object-id array, CFString) behind a small injectable struct of closures with the Core Audio versions as the default, so a test can make any one fail and see the `?(<status>)` reach the produced lines. `static func read(pids: [pid_t]) -> [MeetingInputProcess]`: PID → process object via `kAudioHardwarePropertyTranslatePIDToProcessObject` (copy the 15-line read from `tools/audiotap/Sources/AppAudioCapture+PIDTranslation.swift:35-50`; skip PIDs without an object), then `kAudioProcessPropertyIsRunningInput` and `kAudioProcessPropertyDevices` with **`kAudioObjectPropertyScopeInput`** (copy `readOutputDevices` from `ProcessOutputState.swift:90-111` incl. the size re-trim), then per device `kAudioDevicePropertyDeviceUID`, `kAudioObjectPropertyName` and `kAudioDevicePropertyTransportType`, all through the status-keeping reads. `MicInputDetector.swift:250-315` shows the app's existing process-object reads.
- `MeetingMicrophoneVerdict.evaluate(processes:recordedDeviceUID:)`: classify transports by an **allow-list** of physical kinds (built-in, USB, Bluetooth, Bluetooth LE, PCI, FireWire, HDMI, DisplayPort, AirPlay, AVB, Thunderbolt, Continuity Capture wired/wireless); everything else is unidentifiable. Do not reference `kAudioDeviceTransportTypeAutoAggregate`: it is declared deprecated and both packages build with warnings as errors.
- `MeetingMicrophoneWarningPolicy` with `struct Limits { probeEveryTicks = 5; mismatchesBeforeWarning = 2; maxChangeLogEntries = 20 }` and `.production`; a mutating `record(verdict:processes:)` returning what to log, whether to notify and the hint; `reset()` per recording.
- Wiring in `MicrophoneController+MeetingProbe.swift`: the controller (task .3) gains init parameters `notifier: any AppNotifying`, `verboseDiagnostics: @escaping () -> Bool`, `log: any DiagnosticsLogging = OSLogDiagnostics(category: "MeetingMicrophone")`, and an injectable `probeReader: @escaping @Sendable ([pid_t]) -> [MeetingInputProcess] = MeetingMicrophoneProbe.read`, plus a private serial `DispatchQueue` and an in-flight flag. On every 5th `tick()` while attached, when the recorder's `tappedPIDs` is non-empty and its `microphoneTrackActive` is true (the actual track, not the requested source: a microphone that failed to start leaves the source `.appAndMic`, and a given-up track must stop the probing): if a read is in flight, count a skip; else start one on the queue, tagged with an attachment generation, and hop back to the main actor with the result; drop it when the generation is no longer current. Then evaluate against `recordedDevice?.uid`, feed the policy, write lines through `log` (verdict mismatch at `warning`, the rest at `notice`), write the `[debug]` names line only when `verboseDiagnostics()` is true, post via `notifier.notify(title:body:urgency: .timeSensitive)`, publish `meetingAppHint`. `recordingStopped()` writes the stop line (only when a probe ran), clears the hint and resets the policy. Same one-outstanding pattern as `tools/audiotap/Sources/SilentTrackDiagnostics.swift:345-385`.
- Wording (spec): title `Microphone differs from <App>`, body `Recording from <recorded name>, but <App> uses <device names>. Choose the microphone in the menu bar under Microphone.`, hint `<App> uses <device names>`; the app name comes from the attachment, the recorded name from `recordedDevice?.name`.
- `AppState`: pass `notifier` and `{ settings.verboseDiagnostics }` into the controller; `AppState+Microphone.swift` passes `microphone.meetingAppHint` into `MicrophoneMenuState.resolve`.
- `MicrophoneControllerMeetingProbeTests`: injected probe reader, `MockRecorder` with `tappedPIDs` and `micInputDevice`, `RecordingNotifier` (`Tests/RecordingNotifier.swift`), `RecordingDiagnostics` (`Tests/RecordingDiagnostics.swift`): two mismatching probes → one notification with `.timeSensitive`, hint set; a match clears the hint; empty `tappedPIDs`, or `microphoneTrackActive` false from the start (failed mic start) or turning false mid-recording (give-up), never calls the reader or stops calling it; an active track whose `micInputDevice` has no UID yields `recordedMicrophoneUnknown`; a reader fed a failing name read produces `?(<status>)` in the `[debug]` line; a result arriving after `recordingStopped()` changes nothing; a blocked reader makes the next due probe a counted skip; the `[debug]` line appears only with verbose on.
- `docs/architecture-macos.md`: rows for the four new files.

### Investigation targets
**Required** (read before coding):
- `tools/audiotap/Sources/ProcessOutputState.swift` — readings that keep their status, device-list read
- `tools/audiotap/Sources/SilentTrackDiagnostics.swift:330-385` — one read in flight, results off the write queue
- `app/MeetingTranscriber/Sources/ChannelHealthController+LogLines.swift` — pure log-line builders tested by wording
- `app/MeetingTranscriber/Sources/DiagnosticsLogging.swift` — the log seam (it writes `.public`, so builders must never put a UID or an unconditional name in)
- `app/MeetingTranscriber/Sources/ChannelHealthController+Alerts.swift:10-45` — notification wording and urgency style

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/MicInputDetector.swift:246-316` — app-side Core Audio process reads
- `tools/audiotap/Sources/AppAudioCapture+SilentTrackDiagnostics.swift` — privacy note on these lines

### Key context
- Never run a Core Audio read on the main thread or block the main actor waiting for one (issue #588); a read that never returns must only cost skipped probes.
- The probe needs no `#if APPSTORE`; build both variants (`./scripts/pre-push.sh --with-appstore`) before handing back.
- Run: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<dir>/home swift test --parallel --filter 'MeetingMicrophone|MicrophoneController|MicrophoneMenuState|MenuBar' > /private/tmp/<dir>/app.log 2>&1`, read the log. Lint with the pinned tools.
- No live run is required from this task: the unit tests drive every decision, and the real-call evidence (Teams, Zoom) is the owner's check after merge. Do not quit or restart the installed app (`/Applications/MeetingTranscriber-Dev.app`) yourself.
## Acceptance
- [ ] `MeetingMicrophoneVerdict` tests cover match, mismatch and each undetermined reason (`noProcessCapturingInput`, `unidentifiableDevice` incl. aggregate, virtual, unknown and unlisted transports, `unreadableProperty`, `recordedMicrophoneUnknown`); transports are classified by an allow-list and the deprecated auto-aggregate constant is not referenced.
- [ ] `MeetingMicrophoneWarningPolicy` tests show: two consecutive mismatches give exactly one notification per recording; a match or undetermined resets the count; the hint exists only while the latest verdict is a mismatch; log entries on first probe and changes only, capped at 20 change entries with one cap line; a stop summary with last verdict, probes, skipped probes and warned.
- [ ] Log-line tests show the exact wording of R5, `?(<status>)` for failed reads (including a failed name read fed through the injectable raw reads into the `[debug]` line), no device name in any unconditional line, names only in the `[debug]` line, and no device UID in any line.
- [ ] Controller tests with an injected reader show: the reader is called every 5th tick only while the recording has tapped processes and a running microphone track (`microphoneTrackActive`), never after a failed mic start or a give-up; never on the main thread's critical path (results arrive by a main-actor hop); a blocked read turns the next due probe into a counted skip; a result after `recordingStopped()` changes nothing; two mismatches post one `.timeSensitive` notification naming the app, its device and the recorded microphone; the menu state shows `<App> uses <device>` while the mismatch holds and not after a match or the recording's end.
- [ ] `./scripts/lint.sh` and `./scripts/pre-push.sh --with-appstore` pass; the focused suites are green (log read from a file).
- [ ] `docs/architecture-macos.md` has rows for the four new files.
## Done summary
During a recording that taps a meeting app and captures the microphone, the app now checks every five seconds which input devices the meeting app uses and writes what it finds to the log. When two probes in a row show the meeting app only on identifiable physical devices, none of them the recorded microphone, the app posts one time-sensitive notification per recording, `Microphone differs from <App>`. The menu's Microphone entry shows `<App> uses <device>` while the latest probe is a mismatch.

The work is split so every decision is tested without Core Audio.
- `MeetingMicrophoneProbe` only reads. It translates each pid to a process object, reads `isRunningInput` and the device list on the input scope, then reads UID, name and transport per device. Every read keeps its OSStatus, the name included. The four raw reads are injectable through `RawReads`.
- `MeetingMicrophoneVerdict.evaluate` returns match, mismatch or undetermined with a reason. It classifies transports by an allow-list of 13 physical kinds and never names the deprecated auto-aggregate constant.
- `MeetingMicrophoneWarningPolicy` holds `Limits.production` (5 ticks, 2 mismatches, 20 change entries) and builds every log line, the notification and the hint.
- `MicrophoneController+MeetingProbe.swift` runs one read at a time on the controller's own serial queue, never on the main thread. A probe that falls due while a read is still out is skipped and counted. The result comes back by a main-actor hop. It is dropped unless its recording is still attached and its microphone track is still running.
- `AppState` passes the notifier, and `AppState+Microphone` passes `microphone.meetingAppHint` into the menu state.
- `docs/architecture-macos.md` has rows for the four new files.

Tests (29 new; the pure-type and controller suites were each seen red against stubs first):
- `MeetingMicrophoneVerdictTests` (7) has one test for match, mismatch and each undetermined reason. `unidentifiableDevice` covers aggregate, auto-aggregate as `0x66677270`, virtual, unknown, unlisted `rscr`, and a capturing process that lists no device. `unreadableProperty` covers a failed isRunningInput, device list, UID and transport read. `testEveryPhysicalTransportIsIdentifiable` pins the allow-list.
- `MeetingMicrophoneWarningPolicyTests` (10) cover these cases: one notification after two consecutive mismatches per recording; a reset by a match or undetermined verdict; the hint only while the latest verdict is a mismatch; exact R5 wording for the first entry, an unchanged probe and a change entry. `testAFailedReadIsShownAsItsStatus` checks `?(<status>)` for isRunningInput, the device list, transport, UID (as the device's role) and the `[debug]` name. They also cover transport labels, the 21st change giving one cap line and then nothing, and the stop line. `testNoLineCarriesAUIDAndOnlyTheDebugLineNamesDevices` uses distinctive UIDs and names.
- `MeetingMicrophoneProbeTests` (1) feeds fake raw reads. It checks that a pid without a process object is skipped, that each failed read keeps its status, and that the device list is read on the input scope.
- `MicrophoneControllerMeetingProbeTests` (11) cover these cases:
  - the reader runs on tick 5, not on ticks 1 to 4, off the main thread, with the recorder's `tappedPIDs`;
  - no read with empty `tappedPIDs` or after a failed mic start, and probing stops at a give-up;
  - a result still out at a give-up is dropped and the hint clears (seen red without the guard);
  - a probe due during a blocked read becomes `skippedProbes=1`;
  - a result arriving after its recording stopped, with the next recording already attached, changes nothing;
  - two mismatches give exactly one `.timeSensitive` notification with the exact title and body;
  - the hint clears at a match and at stop;
  - a microphone without a UID gives `recordedMicrophoneUnknown`;
  - the `[debug]` line appears only with verbose on;
  - a failed name read through `RawReads` reaches the `[debug]` line as `name=?(2003332927)`.

Not covered by a unit test:
- The real Core Audio reads. CI has no meeting app or audio hardware, and the Teams and Zoom calls are the owner's check after merge.
- The `?(0)` branch of the CFString read, which answers noErr with no string.
- The one-line hint pass-through in `AppState+Microphone`. `MicrophoneMenuStateTests.testTheMeetingAppHintPassesThroughUnchanged` covers `resolve`.

Baseline: green. The focused filter `MeetingMicrophone|MicrophoneController|MicrophoneMenuState|MenuBar` passed 148 tests (rc 0) at d87e045e before any edit.
Gates at 7aafa409:
- The task filter passed 177 tests (rc 0).
- The spec's app Quick filter plus the suites that build `AppState` (`Microphone|MeetingMicrophone|WatchLoopTests|MenuBar|AppState|WatchingController`) passed 409 tests (rc 0).
- `./scripts/lint.sh` found 0 violations in 729 files.
- `./scripts/pre-push.sh` gave rc 0 with 0 warnings.
- `swift build -c release -Xswiftc -DAPPSTORE` gave rc 0 with 0 warnings.
- A clean `xcodebuild build-for-testing` plus `swiftlint analyze --strict` found 0 violations in 656 files. It ran on 35cac967, before the review fix. The fix adds one declaration, `recordProbeStarted()`, which the controller calls.
- Line counts: `AppState.swift` 587 and unchanged, with `AppState.init` at its previous length. `MicrophoneController.swift` 196.

Decision: the verbose flag is read from the controller's own `settings.verboseDiagnostics`, with no injected `verboseDiagnostics` closure · rule 6 · the controller already holds `settings`, so the `AppState` call stays one line inside the 60-line init body. Flip at `MicrophoneController+MeetingProbe.swift:adoptMeetingProbe`; test `testTheDebugLineIsWrittenOnlyWithVerboseAudioLogging`.
Assumption: the menu hint shows from the first mismatching probe, while the notification waits for the second · alternatives: show the hint only after the second consecutive mismatch, together with the notification · flip at: `MeetingMicrophoneWarningPolicy.swift:record` (`outcome.hintDevices`) · test: `testTheHintShowsOnlyWhileTheLatestVerdictIsAMismatch`, `testTwoMismatchingProbesPostOneTimeSensitiveNotificationAndShowTheHint` · rule 4
Assumption: several device names are joined with `, `. An unreadable device name reads `an unnamed device`, a recorded microphone without a name reads `an unnamed microphone`, and a missing app name reads `the meeting app` · alternatives: `A and B`; leave unnamed devices out · flip at: `MeetingMicrophoneWarningPolicy.swift:deviceNames` and `notification(appName:recordedName:devices:)`, `MicrophoneController+MeetingProbe.swift:adoptMeetingProbe` · test: `testTheNotificationAndHintWording` · rule 4
Decision: verdict precedence is match first, then `unreadableProperty`, `noProcessCapturingInput` and `unidentifiableDevice`. `recordedMicrophoneUnknown` comes last, reported only when the meeting app's side was identifiable · rule 6 · the verdict line then says what the meeting app's side showed. Tests are in `MeetingMicrophoneVerdictTests`.
Decision: a process that captures input but lists no device makes the verdict `unidentifiableDevice`, so nothing warns · rule 1 · D3 says warn only where the probe can tell. Test `testUnidentifiableDevice`.
Decision: transports are logged by name for the allow-listed kinds plus Aggregate, Virtual and Unknown, and as their four-char code otherwise (`fgrp`) · rule 6 · test `testTransportsWithoutAPhysicalKindAreNamedOrGivenAsTheirCode`.
Decision: a process line is left out only when the process reads `isRunningInput=false` and lists no device, so a failed read never hides a line · rule 1 · R5 says an unreadable property appears as `?(<status>)`. Tests `testTheFirstProbeLogsAnUnchangedProbeLogsNothingAndAChangeLogs`, `testAFailedReadIsShownAsItsStatus`.
Decision: one `[debug]` line per entry lists each device once across the logged processes, after the entry lines, and only when a device is listed · rule 6.
Decision: the cap line reads `Meeting app microphone: 20 changes logged in this recording, further changes not logged` · rule 6 · test `testThe21stChangeLogsOneCapLineAndThenNothing`.
Decision: `probes` counts reads started. The stop line is written when a read started or was skipped, and `lastVerdict=none` covers a read that never came back · rule 1 (review finding, R5 stop summary) · tests `testTheStopLineCarriesLastVerdictProbesSkippedProbesAndWarned`, `testAResultArrivingAfterItsRecordingStoppedChangesNothing`.
Decision: `MicrophoneController.init` defaults `notifier` to `SilentNotifier()`, `log` to `OSLogDiagnostics(category: "MeetingMicrophone")` and `probeReader` to the Core Audio read · rule 6 · the existing `MicrophoneControllerTests`, outside this task's Touches, compile unchanged. `AppState` passes the real notifier.
Decision: the new code comments cite no issue number, because the fork's #43 would point at a different issue in the original · rule 6.

Follow-ups: none filed by this task.
Feature map: the repo has no `.flow/features/`. There is no new user route; the hint is a line in the existing menu bar → Microphone entry.

Tier: session (jev-unavailable(no_key)) — explicit routing block: implementer opus at xhigh

stage: impl-review - ran [2026-10-09T08:44:41Z..2026-10-09T08:59:55Z] codex gpt-5.6-sol at xhigh (receipt model gpt-5.6-sol, effort xhigh). The first round ran three draws (correctness, contracts, integration), all NEEDS_WORK. They found three defects. A read still out at stop left no stop summary. A result that came back after the mic track gave up could still warn and leave the hint. A failed UID read was logged as `?` without its status. The validator kept all three. One fix commit, 7aafa409, closed all three, with no finding declined. The single re-review returned SHIP with all three marked fixed. The fan-out and re-review ran under `CODEX_SANDBOX=workspace-write` and `FLOW_VALIDATE_REVIEW=1`, the owner's standing override. After each round `git status` showed only flowctl's `.flow/specs` ledger change. The lesson was captured as memory `bug/runtime-errors/async-probe-result-adopted-after-its-2026-10-09`.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 35cac967feb20613a4187903ae25b840ac87fe12, 7aafa4095ecf8216e61a8946cd9dea008754174a
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh43-home swift test --parallel --filter 'MeetingMicrophone|MicrophoneController|MicrophoneMenuState|MenuBar' (177 tests, rc 0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh43-home swift test --parallel --filter 'Microphone|MeetingMicrophone|WatchLoopTests|MenuBar|AppState|WatchingController' (409 tests, rc 0), ./scripts/lint.sh (0 violations, 729 files), ./scripts/pre-push.sh (rc 0, 0 warnings), cd app/MeetingTranscriber && swift build -c release -Xswiftc -DAPPSTORE (rc 0, 0 warnings), xcodebuild build-for-testing + swiftlint analyze --strict (0 violations, 656 files, at 35cac967)
- PRs: