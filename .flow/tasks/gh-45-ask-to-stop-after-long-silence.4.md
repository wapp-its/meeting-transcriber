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
A detected meeting's recording now gets the long-silence question too. When neither recorded track has carried speech for the configured time, "Nothing heard for N minutes" goes up. "Stop now" ends the recording as a meeting end does: it is cut to ten seconds after the last speech, processed or written out in record-only mode, and the app keeps watching. The app is then kept out of detection while its call signal stays, so a call app that still signals a call is not recorded or asked about again within seconds. The silence question gives way to "the meeting seems to have ended" while that one is open, and every other way the recording ends withdraws it and ends exactly as before.

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)
stage: impl-review - skipped(policy: parallel-wave - conductor owns the gate)
baseline: green. The conductor found the spec branch at fc9147ad green (task .3's focused tests rc=0, lint rc=0). Lint was re-run here before the first edit: rc=0, 0 violations in 772 files (/tmp/gh45-tick/t4-lint-baseline.log). The focused tests were not re-run before the edit; the conductor's green result was reused.

### What changed

- `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift`
  - `waitForMeetingEnd` runs the silence step once per poll, after `WatchLoopEndPolicy.step` and before its decision is carried out. A silence stop logs `recording_auto_stop trigger=auto reason=silence_stop silent_s=<n>`, calls gh-94's `holdRedetection(of:)` and returns the stop's `cutAt` (nil means no cut). `handleMeeting` already hands that value to `cutBack` and `enqueueRecording`, so `WatchLoop.swift` is unchanged (still 600 lines).
  - The wait's `defer` also calls `endSilencePrompt()`. Every way out (a stop by hand, Stop Watching, the countdown, the cap, an error) therefore withdraws an open silence question.
  - New private `stepSilencePrompt(beside:from:)`:
    - It returns nil without running the policy when the decision is `.stop`.
    - It passes `held: true` when the phase before the poll is `.askingToEnd` or the decision is `.askToEnd`, and `false` otherwise.
    - `WatchLoopEndPolicy` gets no new input.
- `app/MeetingTranscriber/Tests/WatchLoopSilencePromptDetectedTests.swift` (new): 4 tests, 2 of them table-driven. They use `TestClock`, a scripted detector, `MockRecorder` with WAV tracks, the injected `speechActivity`, and a notifier double that records posts and withdrawals in order.
- `WatchLoop.swift` and `WatchLoop+SilencePrompt.swift`: no change was needed.

### Tests (per acceptance bullet)

Red run before the change: `/tmp/gh45-tick/t4-tests-red.log`, rc=1. All 4 new tests failed for the stated reason: no silence question is posted on a detected meeting (XCTUnwrap of the first question failed; silence lines were `[]`; no hold was set, so `recorderStarts` climbed to 106 and 111).

1. **Question and "Stop now"** (`testStopNowEndsASilentDetectedRecordingCutAndWatchingGoesOn`):
   - The question goes up at 25 s with the R1 title and body.
   - "Stop now" ends the recording at 27 s. All three tracks hold 240000 frames, which is the last speech at 5 s plus 10 s.
   - One job is enqueued with the recorder's mix, and the loop is back in `watching`, not `idle`.
   - The notice lines are exactly the post, the `silence_stop` line, `redetect_hold_set app=Microsoft Teams` and `recording_cut kept_s=15`. No title appears in them.
   - Green.
2. **Re-detection hold** (`testAnAppStoppedForSilenceIsHeldUntilItsSignalHasGoneOnce`): runs for an app that records without asking and for one that asks first.
   - At least 6 more polls run with no recorder start and no consent prompt.
   - One poll without the signal writes `redetect_hold_released`.
   - The next call is recorded, and prompted as usual.
   - Green.
3. **One question at a time** (`testTheSilenceQuestionGivesWayToTheMeetingEndQuestion`): runs for "Keep recording" and for the signal coming back.
   - The silence question is withdrawn in the poll that posts gh-54's question, before that one goes up (checked on the ordered event list).
   - No silence question is asked while gh-54's question is open.
   - The next silence question comes exactly 20 s after the 60 s close: none before the poll at 80 s, one at 80 s.
   - The log lines are `posted`, `withdrawn reason=held`, `posted silent_s=80`, `withdrawn reason=ended`.
   - Green.
4. **Every other end** (`testEveryOtherEndWithdrawsTheSilenceQuestionAndEndsAsBefore`): four cases, each with a "Stop now" to the silence question waiting where the end comes first, except the countdown case.
   - Duration cap: `max_duration`, uncut.
   - gh-54's countdown: the silence question is withdrawn with reason `held` when gh-54 asks; the recording ends with `countdown_expired signal_absent_s=40`, cut to 36 s, as gh-54 does.
   - Stop Watching: uncut, withdrawn with reason `ended`.
   - The menu's Stop Recording: `recording_stopped_by_hand`, uncut, withdrawn with reason `ended`.
   - gh-54's tests (`WatchLoopMeetingEndTests` 20, `WatchLoopEndPolicyTests` 18, `WatchLoopTimingTests` 3, `WatchLoopCancellationTests` 2) and gh-94's `WatchLoopStopByHandTests` (9) are unchanged and green.
   - Green.
5. **Focused run**: `/tmp/gh45-tick/t4-tests-verify.log`, rc=0, 392 tests, 0 failures.
6. **Lint and release build**: see Gates.

### Gates

| Gate | Command | rc | Log |
|---|---|---|---|
| Focused tests | `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/mt-gh45-home-t4 swift test --parallel --skip WatchLoopE2ETests --filter "WatchLoop\|WatchingController\|SilencePrompt\|MeetingEnd\|Consent\|MeetingDetector"` | 0 (392 tests, 0 failures) | /tmp/gh45-tick/t4-tests-verify.log |
| Lint | `./scripts/lint.sh` (SwiftFormat 0.63.0, SwiftLint 0.65.1 --strict) | 0 (0/773 files need formatting, 0 violations) | /tmp/gh45-tick/t4-lint.log |
| Release build | `cd app/MeetingTranscriber && swift build -c release` | 0 (0 Swift diagnostics; the "Stale file" lines come from the copied build cache) | /tmp/gh45-tick/t4-release.log |
| Analyzer (CI parity) | `/tmp/gh45-tick/t4-analyze.sh` | xcodebuild 0, analyze 2. The only 2 hits are the known `unused_declaration` at `Sources/RecordingProvider.swift:144` and `:146` (gh-60, on the base). 0 hits in the changed files. | /tmp/gh45-tick/t4-xcodebuild.log, /tmp/gh45-tick/t4-analyze.log |

### Decisions

1. Order inside a poll: the stop-by-hand check runs first, then gh-54's decision. When that decision ends the recording (cap, countdown, its own "Stop now"), the silence step does not run, and that end wins even with a silence "Stop now" waiting. Rule 1: AC "otherwise unchanged from gh-54's behaviour", R7, and task .3's precedent in `monitorManualRecording`.
2. `held` covers the poll whose decision posts gh-54's question through the poll that settles it. The silence count therefore restarts at the moment that question closes, and the next poll runs with `held == false`. Rule 1: R7 "restarts at that moment", the task's Approach, and the AC "a full period later". Pinned by test 3.
3. The silence step runs before gh-54's question is posted, so the withdrawal comes before the post. Rule 1: R7, "never on screen together". Pinned by test 3's event order.
4. A silence "Stop now" that arrived before the poll that would post gh-54's question stops the recording with the silence cut, and gh-54's question is never posted. Rule 1: the spec's edge case "an explicit answer wins" and task .1's policy rule (answer before hold). Switch point: `WatchLoop+MeetingEnd.swift:stepSilencePrompt(beside:from:)`. No dedicated test (see Follow-ups).
5. The hold is placed after every silence stop, even when the signal has already gone; the next watching poll then releases it. This is what gh-94's stop by hand does. Rule 1: the task's Approach ("When the silence step returns a stop for a detected meeting, call `holdRedetection(of: meeting)`").
6. Log order on a silence stop: the auto-stop line, then `redetect_hold_set`, mirroring gh-94's stop-by-hand order. Rule 6.
7. Two commits: the failing tests first, then the change. Rule 6 (conductor rule 4).
8. The base commit was persisted to `/tmp/gh45-tick/t4-base_commit`, not `.flow/tmp/`, because `.flow/` must not be touched. Rule 1.

### Follow-ups

- Optional test for decision 4: a silence "Stop now" arriving before the poll that would post gh-54's question.
- Pre-existing analyzer hits at `Sources/RecordingProvider.swift:144/146` (gh-60): reported, not fixed.
- Pre-existing compiler warnings in `Tests/ViewInspectorIdentifierTests.swift:45/53/64` (main-actor init in a nonisolated context), visible in the xcodebuild log: not this task's.
- The spec's live check on real hardware (the question appears in a quiet room, stays away while people talk) is still the owner's, and is not part of this task.
- No change to how a user reaches a mapped feature (the question is a notification); no feature-map route changed.

### Blockers

none

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: fd34899aeb1a7341f82c4670b27cd30072e85cfc, 8c7ac4294b89c035e20600895e0016892128b2d2
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/mt-gh45-home-t4 swift test --parallel --skip WatchLoopE2ETests --filter "WatchLoop|WatchingController|SilencePrompt|MeetingEnd|Consent|MeetingDetector" -> rc=0, 392 tests run, 0 failures (log /tmp/gh45-tick/t4-tests-verify.log), red run before the change: swift test --filter WatchLoopSilencePromptDetectedTests -> rc=1, 4 of 4 tests failed, no silence question posted on a detected meeting (log /tmp/gh45-tick/t4-tests-red.log), ./scripts/lint.sh (SwiftFormat 0.63.0, SwiftLint 0.65.1 --strict) -> rc=0, 0/773 files require formatting, 0 violations in 773 files (log /tmp/gh45-tick/t4-lint.log), cd app/MeetingTranscriber && swift build -c release -> rc=0, Build complete, 0 Swift compiler diagnostics (log /tmp/gh45-tick/t4-release.log), /tmp/gh45-tick/t4-analyze.sh (clean xcodebuild build-for-testing + swiftlint analyze --strict) -> xcodebuild rc=0, analyze rc=2: 2 pre-existing unused_declaration hits at Sources/RecordingProvider.swift:144 and :146, 0 hits in changed files (logs /tmp/gh45-tick/t4-xcodebuild.log, /tmp/gh45-tick/t4-analyze.log)
- PRs: