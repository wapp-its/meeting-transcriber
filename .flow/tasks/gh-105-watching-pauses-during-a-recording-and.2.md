---
satisfies: [R2, R6, R7]
---
# gh-105-watching-pauses-during-a-recording-and.2 Resume watching after a manual recording ends

## Description
The controller side of R2: a pending resume intent per manual recording, the loop's end-of-manual-recording signal, and "start unless already watching" with task .1's holds. The automation API's cancel and answer ordering, and removing the old API-only restore, are task .3.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchingController.swift` (stored state and hook lines only; it is at 581 lines), new `app/MeetingTranscriber/Sources/WatchingController+ResumeWatching.swift`, `app/MeetingTranscriber/Sources/WatchingController+WatchControl.swift`, `app/MeetingTranscriber/Sources/WatchLoop.swift` (end signal only; it is at 589 lines), new `app/MeetingTranscriber/Tests/WatchingControllerResumeWatchingTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/WatchingController.swift, app/MeetingTranscriber/Sources/WatchingController+ResumeWatching.swift, app/MeetingTranscriber/Sources/WatchingController+WatchControl.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Tests/WatchingControllerResumeWatchingTests.swift]

### Approach
- **End signal (WatchLoop).** Add `var onManualRecordingEnded: (() -> Void)?` and call it as the last step of `WatchLoop.stopManualRecording()` (`WatchLoop.swift:302-327`), after the `.idle` update. Every manual ending passes there: the controller's stop (`WatchingController.swift:528-531`), the monitor's stops (`WatchLoop+ManualRecording.swift:26-34`), a recorder throwing at stop. `stop()` (`:213-228`, used by `quit()` at `MeetingTranscriberApp.swift:411-413`) must not call it (spec A4). Keep it to the property and one call.
- **Intent (controller).** One stored `Bool` (pending resume) and one stored `Task<Void, Never>?` (the resume in flight) in `WatchingController.swift`. On 2026-10-20 that file is at 600 lines and `WatchLoop.swift` at 599, and lint fails `--strict` above 600 (`.swiftlint.yml:128`), so first move an existing self-contained block of each main file into a `<Type>+<Topic>.swift` extension (its own commit, no behaviour change) and only then add the stored state and hook lines. `stopManualRecording` is now `stopManualRecording(cutAt:)` at `WatchLoop.swift:334-359` and a third monitor ending, the silence stop (`WatchLoop+ManualRecording.swift:39`), also passes through it. Set the intent in `performManualRecording` right where the active auto loop is stopped (`:440-456`, after `joinStart()`), never on the `.blockedByActiveRecording` early return. Wire `loop.onManualRecordingEnded` on the manual loop it builds (`:462-484`).
- **When the resume runs** (new extension, `scheduleResumeIfPending()`). It always creates a separate resume task on the main actor; nothing awaits the resume inside the stop or the start that triggered it. Triggers: the end signal, and a manual start whose result is not `.started` (permission refused, failed). For the failed start, schedule it from the start task's body after `performManualRecording` returned (`beginManualRecording`, `WatchingController.swift:417-420`), and in any case the resume task first waits until no manual start is registered (`manualStartTask == nil`; reuse `joinManualStart()` at `:338` or an equivalent wait), because `isManualRecording` includes that registration (`:192-194`) and a resume run while it is set would leave the intent pending with no later end signal to pick it up (spec A6).
- **What the resume does.** After that wait it re-reads state: a manual recording running → leave the intent pending; already watching → clear the intent, do nothing; otherwise start watching through `toggleWatching`'s start branch with two defaulted parameters that existing callers never set: skip `requestStartPermissions` entirely (no `ensureMicAccess`, no `requestScreenRecording`, no `requestAccessibility`: `:280-286`, spec A1) and give the new loop `holdSignallingMeetings()` (task .1) right before `loop.start()` (`:267-268`). Keep every ownership check (`startTask` guard `:220`, the `isManualRecording` re-check `:233`). **Consume the intent inside the start task at the point the loop is installed** (`watchLoop = loop` at `:267`), never before: when the start bails at the `isManualRecording` re-check, the intent stays pending (spec A7). Settle via `joinStart()` before judging the outcome; a start that should have installed a loop and did not writes one diagnostic line `watch_resume_failed` (R7): check how controller lines reach the persisted diagnostic log (os_log subsystem `com.meetingtranscriber`, notice level) and use that.
- Never call `toggleWatching()` bare for a resume: it stops a running auto loop. Never route the resume through `startWatching()` as it is: that path requests permissions.
- Expose the resume task for task .3 and tests (`joinResume()` in the style of `joinStart()` at `:324`).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchingController.swift:195-280, 320-370, 430-531` — toggleWatching, joins, manual start/stop
- `app/MeetingTranscriber/Sources/WatchLoop.swift:198-228, 296-327` — start/stop and manual stop
- `app/MeetingTranscriber/Sources/WatchingController+WatchControl.swift` — startWatching/stopWatching
- `app/MeetingTranscriber/Tests/XCTestCase+WatchingController.swift` — controller factory with detector/recorder seams

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/WatchingControllerStopRecordingTests.swift`, `WatchingControllerManualRecordingTests.swift` — manual recording through the controller
- `app/MeetingTranscriber/Tests/TestHelpers.swift:229-253`, `FixedMeetingDetector.swift`

### Key context
- After `WatchLoop.stopManualRecording()` the loop is `.idle` with `manualRecordingInfo == nil`, so `isActive` and `isManualRecording` are both false for it (`WatchLoopState.swift:29-31`, `WatchLoop.swift:33-35`): a monitor-driven stop leaves an idle non-nil `watchLoop`, which `toggleWatching` treats as not running (start branch).
- `WatchingController` tests are `@MainActor`; stub the mic gate as the existing factory does so the resume never waits on a real prompt.

## Acceptance
- [ ] `WatchingControllerResumeWatchingTests`, each starting with watching on and a manual recording started through the controller's real entry points (`startMicrophoneRecording()`, `startManualRecording(pid:appName:title:)`): Stop Recording, the target app exiting (monitor stop, no controller call), the duration cap, a recorder throwing at stop, a permission refusal at start and a recorder failing to start each end, after `joinResume()`, with `isWatching` true and exactly one watch loop; the resumed loop holds a meeting that was signalling (no recording, no consent prompt while it keeps signalling).
- [ ] No prompt at resume: the factory's `ensureMicAccess`, `requestScreenRecording` and `requestAccessibility` seams are counted, and a resume invokes none of them, also when the permission seams report access missing.
- [ ] Watching off before the manual recording: after it ends, `isWatching` stays false.
- [ ] Start Watching pressed between the end and the resume: exactly one loop, watching on. A second manual recording started before the resume ran: watching stays off until that one ends, then resumes once.
- [ ] Interleaving: a second manual start that registers after the resume began but before its watch loop was installed makes that start bail; the intent stays pending, and watching resumes once when the second recording ends.
- [ ] Quitting during a manual recording (the loop's `stop()`): no watch loop starts, the intent is not consumed into a start.
- [ ] Record-only mode: the resume behaves the same.
- [ ] A start that fails at resume leaves watching off and logs `watch_resume_failed` (assert through the test's log/diagnostics seam).
- [ ] Existing `WatchingController*` and `MenuBarView*` suites pass.
- [ ] Focused run green, read from the log file: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "WatchingController|WatchLoopResumeHold|WatchLoopStopByHand|ManualRecording" > /private/tmp/mt-gh105-t2.log 2>&1; echo "exit=$?"`.
- [ ] Lint 0 violations, and `./scripts/pre-push.sh --with-appstore` (release build, both variants) is clean.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
