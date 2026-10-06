---
satisfies: [R1, R2, R3, R4, R6, R7, R8]
---
# gh-45-ask-to-stop-after-long-silence.3 Ask and stop manual recordings after long silence

Touches: app/MeetingTranscriber/Sources/WatchLoop+SilencePrompt.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/WatchLoop+ManualRecording.swift, app/MeetingTranscriber/Sources/WatchLoopEndPolicy.swift, app/MeetingTranscriber/Sources/WatchingController.swift, app/MeetingTranscriber/Tests/WatchLoopSilencePromptTests.swift, app/MeetingTranscriber/Tests/RecordingNotifier.swift

## Description
Wires the policy into `WatchLoop` and delivers the whole feature for manual recordings (R1–R4, R6's live effect, R7's "ends any other way" part, R8): the per-poll silence step shared with task .4, the question through gh-54's notifier calls, the out-of-band answer, "Stop now" with the cut, withdrawal on every way a recording ends, the log lines, and the wiring in `WatchingController` for both loops. Detected meetings follow in task .4, which reuses the step built here.

Line numbers below are from `wapp/main` at 65888b53, before gh-54 merged; gh-54 moves code in `WatchLoop.swift` (its meeting-end wait now lives in `WatchLoop+MeetingEnd.swift`), so find the functions by name.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchLoop+SilencePrompt.swift` (new), `app/MeetingTranscriber/Sources/WatchLoop.swift`, `app/MeetingTranscriber/Sources/WatchLoop+ManualRecording.swift`, `app/MeetingTranscriber/Sources/WatchLoopEndPolicy.swift` (gh-54's `AutoStopReason`), `app/MeetingTranscriber/Sources/WatchingController.swift`, `app/MeetingTranscriber/Tests/WatchLoopSilencePromptTests.swift` (new), the test notifier double gh-54 extended for its question (likely `app/MeetingTranscriber/Tests/RecordingNotifier.swift`)
**Touches:** [app/MeetingTranscriber/Sources/WatchLoop+SilencePrompt.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/WatchLoop+ManualRecording.swift, app/MeetingTranscriber/Sources/WatchLoopEndPolicy.swift, app/MeetingTranscriber/Sources/WatchingController.swift, app/MeetingTranscriber/Tests/WatchLoopSilencePromptTests.swift, app/MeetingTranscriber/Tests/RecordingNotifier.swift]

### Approach
- `WatchLoop.init` gains two dynamic accessors with inert defaults, after the pattern of `recordOnly` (`WatchLoop.swift:52-54`, `:134`): `speechActivity: @escaping () -> SpeechActivity? = { nil }` and `silencePromptAfter: @escaping () -> TimeInterval? = { nil }`. The defaults keep every existing test and the meeting simulator unaffected.
- One stored property holds all new per-loop state, for example `var silencePrompt = SilencePromptRuntime()` (a small struct declared in the new file): the policy state, the open question's id, the answer parked for the next poll, the manual recording's cut anchor, and (task .4) the re-detection hold.
- `WatchLoop+SilencePrompt.swift`:
  - `func stepSilencePrompt(held: Bool, trigger: RecordingSidecar.Trigger) -> SilenceStop?`, called once per poll: take and clear the parked answer, run `SilencePromptPolicy.step` with `nowProvider()`, `speechActivity()`, `silencePromptAfter()`, then act. `.ask`: withdraw the open id first (reason `replaced`), then post under a fresh UUID with gh-54's `notifier.askBeforeEndingRecording(id:title:body:onAnswer:)`, title from `SilencePromptPolicy.questionTitle(silentFor:)`, body `SilencePromptPolicy.questionBody`; the `onAnswer` closure parks the answer only while that id is still the open one (copy gh-54's `askToEnd` / `receiveMeetingEndAnswer` in `WatchLoop+MeetingEnd.swift`, including its main-actor hop). `.withdraw`: `notifier.withdrawMeetingEndQuestion(id:)` and forget the id. `.stop`: forget the id (the question is answered) and return `SilenceStop(cutAt:silentFor:)`.
  - `func endSilencePrompt()`: withdraw an open question (reason `ended`) and reset the policy state, question id and parked answer; called on every way a recording ends. It does not clear the manual cut anchor (overwritten at every start, read at stop) nor task .4's re-detection holds (they belong to the loop, not the recording).
  - Log lines through gh-54's `diagnostics` (`DiagnosticsLogging`): `silence_question_posted trigger=<auto|manual> silent_s=<n>` and `silence_question_withdrawn trigger=<…> reason=<speech|kept|held|off|replaced|ended>`. Whole seconds, no meeting title, no window text.
- gh-54's `AutoStopReason` gains `case silenceStop = "silence_stop"`, and its `logLine` an optional silence length rendered as `silent_s=<n>`; the stop writes `recording_auto_stop trigger=<…> reason=silence_stop silent_s=<n>`.
- Manual recordings:
  - `startManualRecording` (`WatchLoop.swift:235-279`) stores the cut anchor as `nowProvider()` right after `recorder.start` succeeds, the way gh-54's `handleMeeting` takes `recordingStartedAt`.
  - `monitorManualRecording` (`WatchLoop+ManualRecording.swift:14-41`) calls `stepSilencePrompt(held: false, trigger: .manual)` on each poll; on a stop it logs the stop line, calls `stopManualRecording(cutAt:)` and returns.
  - `stopManualRecording(cutAt: Date? = nil)` (`WatchLoop.swift:281-305`): read the stored anchor into a local, then call `endSilencePrompt()`; after `recorder.stop()`, when `cutAt` is non-nil, run gh-54's `cutBack(_:to:startedAt:)` with that anchor and pass its result as `recordedUntil` to `enqueueRecording` (the parameter gh-54 added for the record-only sidecar). The menu's Stop, the app-exit stop and the duration cap keep calling it without a cut point: uncut, question withdrawn.
  - `stop()` and `cleanupManualRecording()` also call `endSilencePrompt()`.
- `WatchingController`: both `WatchLoop(...)` constructions (auto at `WatchingController.swift:240-258`, manual at `:468-481`) pass `speechActivity: { [channelHealth] in channelHealth.speechActivity }` and `silencePromptAfter: { [settings] in settings.silencePromptAfter }`.

### Investigation targets
**Required** (read before coding):
- gh-54's `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift` — `askToEnd`, answer parking by id, `withdrawMeetingEndQuestion`, `cutBack`
- gh-54's `app/MeetingTranscriber/Sources/NotificationManager.swift` meeting-end section and the `AppNotifying` additions — the question API this task reuses unchanged
- `app/MeetingTranscriber/Sources/WatchLoop.swift` — `startManualRecording`, `stopManualRecording`, `stop`, `cleanupManualRecording`, `enqueueRecording`
- `app/MeetingTranscriber/Sources/WatchLoop+ManualRecording.swift:14-41` — the manual poll loop

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/WatchLoopMonitorTests.swift:15-37` — manual recording driven by `TestClock`, `MockRecorder`, `pidAliveCheck`
- gh-54's tests for `RecordingCut` — WAV-fixture helpers for checking where each track ends
- `app/MeetingTranscriber/Sources/WatchingController.swift:440-500` — manual loop construction

### Key context
- `WatchLoop.swift` sits near SwiftLint's 600-line `file_length` limit and lint runs `--strict`, so a warning fails it: logic goes into `WatchLoop+SilencePrompt.swift`, state into the one struct property.
- Clocks: the controller stamps speech with `Date()` in production and the loop reads `nowProvider()`, which is `Date.init` in production. Tests inject `speechActivity` directly in `TestClock` terms; never pair a real `ChannelHealthController` with a `TestClock`.
- A stop when no speech was ever heard has `cutAt == nil` and stays uncut (A2).
- Reuse gh-54's question API and its notification category as they are; no new category, no new `AppNotifying` member, no change to its urgency (A3).
- `Tests/TestHelpers.swift` is at the 600-line cap; extend the notifier double in its own file or keep test-local doubles in the new test file (pattern: the private doubles in `Tests/WatchLoopAskBeforeRecordingTests.swift:15-98`).
## Acceptance
- [ ] `WatchLoopSilencePromptTests` (manual recordings, `TestClock`, `MockRecorder`, injected `speechActivity`, a notifier double that records posted ids, titles and bodies plus withdrawn ids and can deliver an answer for an id): no question before the configured time and exactly one at it, with the spec's title and body; "Stop now" leaves the loop idle with the recorder stopped and a job enqueued (and, in record-only mode, the sidecar written with the cut point as its stop time); "Keep recording" withdraws and the next question comes only a full period after the answer; an unanswered question is withdrawn and replaced after another period; speech withdraws it; an answer under an old id changes nothing; the menu's stop (`stopManualRecording()`) and the app-exit stop with a question open withdraw it and leave the recording uncut; switching the setting off withdraws it at the next poll.
- [ ] Cut, with WAV fixtures, through the full `monitorManualRecording` → `stopManualRecording(cutAt:)` path (not by calling `cutBack` directly): after "Stop now" every saved track (mix, app, mic) ends at the same timeline point, last speech + 10 s, honouring `micDelay`; a recording with no speech heard at all is left uncut; speech coming back a few seconds before "Stop now" leaves every track uncut and, in record-only mode, the sidecar's stop time is the real stop, never later; a forced cut failure leaves every track as recorded and the recording is still enqueued.
- [ ] The posted, withdrawn and stop log lines appear with their reasons and `silent_s`, and none contains the recording's title (assert with a distinctive title).
- [ ] With the default inert accessors, `WatchLoopMonitorTests`, `WatchLoopTests` and `WatchLoopCancellationTests` stay green unchanged.
- [ ] Focused run green: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch dir> swift test --parallel --skip WatchLoopE2ETests --filter "WatchLoop|WatchingController|SilencePrompt|NotificationManager|RecordOnly|ManualRecording" > <log file> 2>&1`, read from the log file. (`WatchLoopE2ETests` needs downloaded models and fails under a scratch home; CI runs it.)
- [ ] `./scripts/lint.sh` reports no violations with the pinned tools, and `swift build -c release` is clean (the release build catches `Sendable` diagnostics the debug build tolerates; `./scripts/pre-push.sh` runs it).
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
