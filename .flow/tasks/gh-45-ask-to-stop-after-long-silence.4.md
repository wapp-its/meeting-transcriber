---
satisfies: [R1, R2, R5, R7, R8]
---
# gh-45-ask-to-stop-after-long-silence.4 Silence question for detected meetings

Touches: app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/WatchLoop+SilencePrompt.swift, app/MeetingTranscriber/Tests/WatchLoopSilencePromptDetectedTests.swift

## Description
Extends the silence question to detected meetings (R1–R4 and R2's "as a meeting end does" for them, R5, R7, R8's hold lines): the per-poll step from task .3 runs inside gh-54's meeting-end wait, held while gh-54's own question is open; a silence "Stop now" ends the recording through the same cut-and-enqueue path gh-54's stops take, watching continues, and the same app is kept out of detection until its call signal has gone once.

Line numbers below are from `wapp/main` at 65888b53, before gh-54 merged; find the functions by name.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift` (gh-54), `app/MeetingTranscriber/Sources/WatchLoop.swift`, `app/MeetingTranscriber/Sources/WatchLoop+SilencePrompt.swift`, `app/MeetingTranscriber/Tests/WatchLoopSilencePromptDetectedTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/WatchLoop+SilencePrompt.swift, app/MeetingTranscriber/Tests/WatchLoopSilencePromptDetectedTests.swift]

### Approach
- In gh-54's `waitForMeetingEnd` poll loop, call `stepSilencePrompt(held:trigger: .auto)` once per poll with `held` true while gh-54's phase is `.askingToEnd`. Required outcomes, whatever the exact placement:
  - a silence stop ends the wait in that poll and returns its `cutAt` (nil for "do not cut"), which `handleMeeting` already hands to `cutBack` and `enqueueRecording(recordedUntil:)` like gh-54's own stops; log `recording_auto_stop trigger=auto reason=silence_stop silent_s=<n>`;
  - in a poll where gh-54's step posts its question (`.askToEnd`), an open silence question is withdrawn in that same poll (reason `held`), so two questions are never on screen together;
  - when gh-54's question closes without a stop, the next poll runs with `held == false` and the policy's count restarts from the last held poll (task .1's rule 4); nothing extra to do here;
  - every exit of the wait (gh-54's countdown, the cap, cancellation by Stop Watching, an error) ends the silence question: call `endSilencePrompt()` from the wait's `defer` next to gh-54's withdrawal.
- Re-detection hold (R5, A6): **reuse the per-app hold that gh-94 (stop a detected recording by hand) introduced and that is on the base by the time this task runs** (`RedetectionHolds`, `WatchLoop+RedetectionHold.swift`, `holdRedetection(of:)`). When the silence step returns a stop for a detected meeting, call `holdRedetection(of: meeting)`; do not add a second hold dictionary, a second release/exclusion step in `watchLoop()` or a second clearing in `stop()`. Its log lines are gh-94's `redetect_hold_set` / `redetect_hold_released app=<appName>`, and R8's hold-line wording follows them. gh-94's stop-by-hand check runs first in every meeting-end poll; a stop by hand must also end an open silence question (`endSilencePrompt()`). (Coordinator note 2026-10-08: the hold was moved to gh-94, which the owner put first.)
- App names may appear in these lines (the consent code already logs them); meeting titles and window text never.

### Investigation targets
**Required** (read before coding):
- gh-54's `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift` — `waitForMeetingEnd`, its phases and its `defer`
- gh-54's `app/MeetingTranscriber/Sources/WatchLoop.swift` — `handleMeeting` (cut anchor, `cutBack`, `recordedUntil`) and `watchLoop()`
- `app/MeetingTranscriber/Sources/WatchLoop+Consent.swift:74-79` — `appsExcludedFromDetection`, the exclusion this hold joins
- `app/MeetingTranscriber/Sources/PowerAssertionDetector.swift:186-187, 380-385` — the 5 s cooldown after a meeting, which is why the hold is needed

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/WatchLoopAskBeforeRecordingTests.swift:15-98` — scripted detector and notifier doubles for detected meetings
- gh-54's `WatchLoopEndPolicy` tests — how its question is driven to open and close

### Key context
- Without the hold, a meeting whose app still signals a call after the person chose "Stop now" is re-detected within about 5 s: it records again at once for an app set to record without asking, or posts the "Record … meeting?" prompt again otherwise.
- Do not add an input to gh-54's pure `WatchLoopEndPolicy.step` for the silence stop; the silence step returns before or beside it, and gh-54's policy stays the owner of the signal-loss decisions.
- Keep `WatchLoop.swift` under 600 lines (`file_length`, lint `--strict`).
## Acceptance
- [ ] `WatchLoopSilencePromptDetectedTests` (`TestClock`, a scripted detector, `MockRecorder`, injected `speechActivity`, the question-recording notifier double): a detected recording that stays silent gets the question; "Stop now" ends the recording, enqueues it cut at last speech + 10 s, and the loop goes back to watching (not idle).
- [ ] Re-detection hold after a silence stop: while the detector still reports the meeting active, several polls start no recording and post no consent prompt; once `isMeetingActive` has returned false for one poll and the meeting comes back, it is detected and handled as usual. (Independent holds per app and Stop Watching clearing them are covered by gh-94's tests; keep only the silence-specific cases here.)
- [ ] One question at a time: when the signal is lost past the end grace while a silence question is open, the silence question is withdrawn in the same poll that posts gh-54's question; no silence question is posted while gh-54's is open; after "Keep recording" on gh-54's question the next silence question comes only a full period later.
- [ ] Every other end with a silence question open (gh-54's countdown, the duration cap, Stop Watching) withdraws it and is otherwise unchanged from gh-54's behaviour; gh-54's own tests stay green unchanged.
- [ ] Focused run green: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch dir> swift test --parallel --skip WatchLoopE2ETests --filter "WatchLoop|WatchingController|SilencePrompt|MeetingEnd|Consent|MeetingDetector" > <log file> 2>&1`, read from the log file.
- [ ] `./scripts/lint.sh` reports no violations with the pinned tools, and `swift build -c release` is clean.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
