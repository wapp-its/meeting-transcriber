---
satisfies: [R1, R2, R3]
---
# gh-58-notices-for-the-remaining-automatic.1 Warn before the 4-hour maximum and say why a recording stopped

## Description
Adds the cap warning (R1), the cap notice (R2) and the app-exit notice (R3): one pure file with the warning decision and the notice texts, hooked into the two existing poll loops. One task because all three share the builder, the loops and the test doubles.

**Depends on spec gh-54 being merged into this branch.** Before coding, locate its code: `grep -rn 'func waitForMeetingEnd\|enum AutoStopReason\|meetingEndCountdown\|askBeforeEndingRecording\|let diagnostics' app/MeetingTranscriber/Sources app/MeetingTranscriber/Tests`. If `AutoStopReason` / the countdown are not there, stop and report the task blocked on gh-54; do not build gh-54's parts here.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/RecordingStopNotices.swift` (new), `app/MeetingTranscriber/Sources/WatchLoop.swift`, `app/MeetingTranscriber/Sources/WatchLoop+ManualRecording.swift`, the file gh-54 put `waitForMeetingEnd` in (probably `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift`), `app/MeetingTranscriber/Tests/RecordingStopNoticesTests.swift` (new), `app/MeetingTranscriber/Tests/WatchLoopStopNoticeTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/RecordingStopNotices.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/WatchLoop+*.swift, app/MeetingTranscriber/Tests/RecordingStopNoticesTests.swift, app/MeetingTranscriber/Tests/WatchLoopStopNoticeTests.swift]

### Approach
- **Tests first** (clear contract): write `RecordingStopNoticesTests` and `WatchLoopStopNoticeTests` against the API below, run them red, then implement.
- New `RecordingStopNotices.swift`, pure, no I/O, the shape of `ManualRecordingMonitorPolicy.swift:37-66`:
  - `enum RecordingCapWarningPolicy` with `static let defaultLead: TimeInterval = 600` and `static func shouldWarn(elapsed:maxDuration:lead:alreadyWarned:) -> Bool`: true only when not already warned, `maxDuration > lead`, and `maxDuration - lead <= elapsed <= maxDuration`.
  - A builder returning `(title: String, body: String, urgency: NotificationUrgency)` for three cases. Exact texts (`<T>` = the recording's title, `<A>` = the app name, `<L>` = the length phrase, `<N>` = minutes left = `max(1, ceil((maxDuration - elapsed) / 60))`):
    - warning: title `Recording Ends in <N> Minutes` (`Minute` when N is 1), body `"<T>" reaches the maximum length of <L>.`, urgency `.timeSensitive`
    - cap reached: title `Recording Ended`, body `"<T>" reached the maximum length of <L>.`, urgency `.standard`
    - app quit: title `Recording Ended`, body `<A> quit, so the recording "<T>" ended.`, urgency `.standard`
    - empty `<T>`: drop the quoted title (`This recording reaches …`, `The recording reached …`, `<A> quit, so the recording ended.`).
    - `<L>`: whole hours as `N hour(s)` (14 400 s → `4 hours`), otherwise whole minutes `N minute(s)`; it only ever reads the value it is given.
  - The log line builder: `recording_cap_warning trigger=<auto|manual> remaining_s=<Int, rounded>` (use `RecordingSidecar.Trigger.rawValue`, as gh-54's `AutoStopReason.logLine` does). Nothing else in it.
- `WatchLoop.swift`: add `capWarningLead: TimeInterval = RecordingCapWarningPolicy.defaultLead` to `init` (next to `maxDuration`, `WatchLoop.swift:130`) and store it. Production call sites (`WatchingController.swift:240`, `:468`) keep the default; do not touch them.
- `monitorManualRecording` (`WatchLoop+ManualRecording.swift:14-41`): keep a local `var capWarned = false`. On `.continuePolling` only, call `shouldWarn(elapsed:…)`; when true post the warning through `notifier.notify(title:body:urgency:)`, write the log line through gh-54's `diagnostics` at `.notice`, set `capWarned`. On `.stopPidExited` and `.stopMaxDurationExceeded`: read `manualRecordingInfo` (title, appName) **before** `stopManualRecording()` (it clears the info, `WatchLoop.swift:298-304`), keep gh-54's R7 log line, call `stopManualRecording()`, then post the app-quit or cap notice. `.stopPidExited` only happens with a PID, so a microphone-only recording never gets the app-quit notice.
- gh-54's `waitForMeetingEnd`: same local flag and warning call on every poll whose decision is not a stop (trigger `auto`, title `Self.cleanTitle(meeting.windowTitle)`, the title `handleMeeting` gives the job, `WatchLoop.swift:377`). Post the cap notice where gh-54 handles its `.maxDuration` stop, next to its R7 log line; no notice on any other stop reason.
- Elapsed is measured exactly as each loop's cap check measures it (the same `startTime`, the same `maxDuration`), so the warning and the stop agree.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchLoop+ManualRecording.swift` — the manual monitor loop to extend
- gh-54's `waitForMeetingEnd` and `WatchLoopEndPolicy.swift` — the decision cases and where the R7 lines are written
- `app/MeetingTranscriber/Sources/WatchLoop.swift:211-312` — manual start/stop and what `stopManualRecording` clears
- `app/MeetingTranscriber/Tests/WatchLoopMonitorTests.swift` — TestClock + `pidAliveCheck` pattern for the manual loop
- `app/MeetingTranscriber/Tests/WatchLoopTimingTests.swift:46-70` — driving the detected-meeting wait with a `PowerAssertionDetector` stub

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/RecordingNotifier.swift`, `app/MeetingTranscriber/Tests/RecordingDiagnostics.swift` — the spies to assert with
- `app/MeetingTranscriber/Sources/NotificationUrgency.swift` — what the two levels mean

### Key context
- Loop tests run on `TestClock` with `maxDuration: 1.0`, `capWarningLead: 0.5`, `pollInterval: 0.05`; never 4 hours of virtual polls. Filter `RecordingNotifier.calls` by title prefix, since other notifications may be posted.
- Cases for `WatchLoopStopNoticeTests`: manual app recording alive past the cap (one warning, then one cap notice, warning `.timeSensitive`); microphone-only via `startMicrophoneRecording()` (same); app exits before the warning window (`pidAliveCheck` flips to false after a few calls: only the app-quit notice, naming the app); `stopManualRecording()` called by the test before the window (none); a detected meeting held active past the cap (one warning, one cap notice); a detected meeting whose signal drops and whose gh-54 countdown (injected short) expires before the window (none). Drive both detected-meeting cases by calling `waitForMeetingEnd` directly, as `WatchLoopTimingTests` does, so no recorder or cut is involved. Assert the diagnostics line once per warned recording, with no title in it.
- `swiftlint --strict` turns the 600-line `file_length` warning into an error. If `WatchLoop.swift` would pass 600 lines, move a read-only helper into an extension file (the way `WatchLoopState.swift` holds the read-only views) rather than disabling the rule.
- Lint tools are not installed on the owner's Mac: fetch SwiftFormat 0.63.0 and SwiftLint 0.65.1 per `scripts/tool-versions.sh` (release asset + SHA-256) into a scratch dir and run `PATH="<that dir>:$PATH" ./scripts/lint.sh`. Do not `brew install`.

### Verification
- `mkdir -p /private/tmp/mt-gh58/home && cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh58/home swift test --parallel --filter 'RecordingStopNoticesTests|WatchLoopStopNoticeTests|WatchLoopMonitorTests|ManualRecordingMonitorPolicyTests|WatchLoopEndPolicyTests|WatchLoopTimingTests|WatchLoopMeetingEndTests|NotificationManagerMeetingEndTests' > /private/tmp/mt-gh58/t1-tests.log 2>&1`, then read the log (never pipe a test run into tail/head/grep). The last two are gh-54's test classes as named on its branch; if they were renamed, find them with `grep -rln 'waitForMeetingEnd\|askBeforeEndingRecording' app/MeetingTranscriber/Tests` and run all of them.
- `cd app/MeetingTranscriber && swift build --build-tests -Xswiftc -DAPPSTORE > /private/tmp/mt-gh58/t1-appstore.log 2>&1` (App Store variant compiles).
- `./scripts/lint.sh` with the pinned tools on PATH.
## Acceptance
- [ ] `RecordingStopNoticesTests` was run red before the implementation and passes after: the warning decision (before the window, at its start, already warned, past the cap, a cap at or below the lead) and the three texts at 14 400 s / 600 s exactly as specified, plus `1 Minute`, an empty title and each urgency.
- [ ] `WatchLoopStopNoticeTests` passes for the six cases in Key context: exactly one warning per recording that reaches the window, the cap notice only on a cap stop, the app-quit notice only when the targeted app exits, nothing for a stop by hand or a gh-54 meeting end before the window.
- [ ] Each warning writes one `recording_cap_warning trigger=<auto|manual> remaining_s=<n>` line through the loop's diagnostics logger, asserted with `RecordingDiagnostics`; the line carries no title or app name.
- [ ] The stops themselves are unchanged: `WatchLoopMonitorTests`, `ManualRecordingMonitorPolicyTests`, `WatchLoopEndPolicyTests`, `WatchLoopTimingTests` and gh-54's tests (`WatchLoopMeetingEndTests`, `NotificationManagerMeetingEndTests` or their renamed successors) pass without edits to their assertions.
- [ ] `swift build --build-tests -Xswiftc -DAPPSTORE` succeeds and `./scripts/lint.sh` (pinned tools) is clean; no Swift file passes 600 lines.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
