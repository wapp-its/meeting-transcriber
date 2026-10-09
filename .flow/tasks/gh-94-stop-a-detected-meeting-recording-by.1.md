---
satisfies: [R2, R3, R4, R5]
---
# gh-94-stop-a-detected-meeting-recording-by.1 Stop a detected recording by hand in the watch loop, with a per-app re-detection hold

## Description
Builds the watch-loop side of R2–R5: a stop request that the meeting-end wait acts on at its next poll, and the reusable per-app re-detection hold that the watching poll honours. No UI here; task .2 wires the menu. Split this way because this task carries every behaviour that can be tested deterministically on `TestClock`, and proves the approach before any wiring.

**Size:** M
**Files:** new `app/MeetingTranscriber/Sources/RedetectionHolds.swift`, new `app/MeetingTranscriber/Sources/WatchLoop+RedetectionHold.swift`, new `app/MeetingTranscriber/Sources/WatchLoop+StopByHand.swift`, `app/MeetingTranscriber/Sources/WatchLoop.swift`, `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift`, new `app/MeetingTranscriber/Tests/RedetectionHoldsTests.swift`, new `app/MeetingTranscriber/Tests/WatchLoopStopByHandTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/RedetectionHolds.swift, app/MeetingTranscriber/Sources/WatchLoop+RedetectionHold.swift, app/MeetingTranscriber/Sources/WatchLoop+StopByHand.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/WatchLoopState.swift, app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift, app/MeetingTranscriber/Tests/RedetectionHoldsTests.swift, app/MeetingTranscriber/Tests/WatchLoopStopByHandTests.swift]

### Approach
- **Write the tests first** (the contracts are fixed by R2–R5), see them fail, then implement.
- **`RedetectionHolds`** (new file, pure `struct`, `Equatable`): a `[String: DetectedMeeting]` keyed by `meeting.pattern.appName` (the same identity `appsExcludedFromDetection` passes to `checkOnce(excluding:)`, `WatchLoop+Consent.swift:74-79`). API: `heldApps: Set<String>`; `mutating func hold(_ meeting: DetectedMeeting) -> Bool` (true when the app was not held yet; a repeat keeps one entry); `mutating func release(where ended: (DetectedMeeting) -> Bool) -> [String]` (removes and returns, sorted, the apps whose meeting `ended` reports true); `mutating func removeAll()`. No detector inside: the caller passes the check.
- **`WatchLoop.swift`** (580 lines; keep it under 600, `file_length` with `--strict`):
  - next to `meetingEndQuestionID`/`meetingEndAnswer` (`:72-76`), two internal stored properties with one-line doc comments, internal for the extensions like those two: `var stopByHandRequestedAt: Date?` and `var redetectionHolds = RedetectionHolds()`;
  - `handleMeeting` (`:392`): first statement `defer { stopByHandRequestedAt = nil }`, so a request never outlives the recording it was made for (including a recorder start that throws);
  - `stop()` (`:209-223`): `redetectionHolds.removeAll()`;
  - `watchLoop()` (`:332-360`): at the top of each iteration `releaseEndedRedetectionHolds()`; the approved-consent branch (`:338`) also requires the approved meeting's app not to be held; `checkOnce(excluding:)` (`:340`) gets `appsExcludedFromDetection.union(appsHeldFromDetection)`;
  - if the file would pass 595 lines, move `cleanTitle(_:)` and `transcriberState` (`:530-547`, read no private state) into the read-only extension in `WatchLoopState.swift`, unchanged.
- **`WatchLoop+RedetectionHold.swift`** (new, pattern `WatchLoop+Consent.swift`): `holdRedetection(of meeting:)` → when `hold` returns true, `diagnostics.notice("redetect_hold_set app=\(appName)")`; `releaseEndedRedetectionHolds()` → `redetectionHolds.release { !detector.isMeetingActive($0) }`, one `redetect_hold_released app=<appName>` notice per released app; `var appsHeldFromDetection: Set<String>`. Doc comment: why the hold exists (the 5 s cooldown, `PowerAssertionDetector.swift:186-187, 380-385`, would re-detect a call whose signal lingers) and that any stop ending a detected meeting while its signal stays can place one. No fork issue or spec ids in code comments.
- **`WatchLoop+StopByHand.swift`** (new): `@discardableResult func stopDetectedRecording() -> Bool` accepts only while `state == .recording && manualRecordingInfo == nil && currentMeeting != nil`; on acceptance it sets `stopByHandRequestedAt = nowProvider()` only when nil (a repeat keeps the first stamp) and returns true; `func takeStopByHandRequest() -> Date?` returns and clears it.
- **`waitForMeetingEnd`** (`WatchLoop+MeetingEnd.swift:33-72`): first thing inside the `while`, before `MeetingEndPoll` is built: if `let requestedAt = takeStopByHandRequest()`, write `diagnostics.notice("recording_stopped_by_hand trigger=auto")`, call `holdRedetection(of: meeting)`, and return `WatchLoopEndPolicy.cutWhenWatchingStops(phase: phase, answer:)` (`WatchLoopEndPolicy.swift:164-176`) with `takeMeetingEndAnswer()` passed only when its `receivedAt < requestedAt` (nil otherwise). That filter is what makes the order of taps count (spec R3): a "Keep recording" tapped after "Stop Recording" but before this poll must not keep the countdown minutes, and `cutWhenWatchingStops` alone only compares the answer with the countdown's deadline. The existing `defer` withdraws gh-54's question; `handleMeeting` then stops, cuts through `cutBack` (which also remixes a balanced mix) and enqueues as for every other end; `runMeeting` returns the loop to `.watching`. Do not add an input to `WatchLoopEndPolicy.step`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift:19-72` — the wait, its `defer`, cancellation path
- `app/MeetingTranscriber/Sources/WatchLoopEndPolicy.swift:164-176` — `cutWhenWatchingStops`, the cut rule reused here
- `app/MeetingTranscriber/Sources/WatchLoop.swift:72-129, 209-223, 332-447` — stored state, `stop()`, `watchLoop()`, `runMeeting`, `handleMeeting`
- `app/MeetingTranscriber/Sources/WatchLoop+Consent.swift:74-87` — `appsExcludedFromDetection`, `takeApprovedConsentMeeting`
- `app/MeetingTranscriber/Sources/MeetingDetecting.swift:28-45` — `checkOnce(excluding:)` contract (excluded hits still count)

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/WatchLoopMeetingEndTests.swift:13-140, 187-217, 249-262, 342-402` — TestClock harness with `onTick`, WAV tracks, Stop now, Stop Watching during the question
- `app/MeetingTranscriber/Tests/WatchLoopAskBeforeRecordingTests.swift:15-42, 44-62, 145-175` — per-app scripted detector, prompt-counting notifier, loop factory
- `app/MeetingTranscriber/Tests/RecordOnlyE2ETests.swift:87-120` — record-only sidecar assertions on `TestClock`
- `app/MeetingTranscriber/Tests/RecordingNotifier.swift`, `app/MeetingTranscriber/Tests/RecordingDiagnostics.swift`, `app/MeetingTranscriber/Tests/MockRecorder.swift` (`ThrowingRecorder`)

### Key context
- Do not clear the request at the start of the wait: a click while the recorder is still starting (the loop already shows `.recording`) must end the recording at the wait's first poll. The `defer` in `handleMeeting` is what drops it.
- `runMeeting`'s `detector.reset(appName:)` starts a cooldown only inside `checkOnce`; `isMeetingActive` reads the signal directly, so the release check works during the cooldown (`PowerAssertionDetector.swift:355-385`).
- gh-54's tests pin that a stop by hand writes no `recording_auto_stop` line (`WatchLoopMeetingEndTests.swift:374`): keep the new line's prefix distinct. Log lines carry the app name only, never `windowTitle`.
- `WatchLoopMeetingEndTests.swift` is gh-54's suite: leave it unchanged; it must stay green. New tests go in the two new files (copy a trimmed harness; the one there is private).
## Acceptance
- [ ] `RedetectionHoldsTests`: a hold is reported new once; two apps are held independently; `release(where:)` removes and returns only the apps whose meeting is reported ended; `removeAll()` empties it.
- [ ] `WatchLoopStopByHandTests` on `TestClock` (poll 1 s, end grace 10 s, countdown 120 s, 30 s WAV tracks): with the signal present, `stopDetectedRecording()` at t = 20 returns true, `handleMeeting` returns at t = 20, the recorder is stopped once, one job is enqueued, every track keeps all its frames, no meeting-end question was asked, the notice lines are exactly `recording_stopped_by_hand trigger=auto` and `redetect_hold_set app=Microsoft Teams`, and no line starts with `recording_auto_stop`.
- [ ] Signal lost at 5 s, question asked at 15 s, stop by hand at 30 s (30 s tracks, so clock and audio agree, as in `WatchLoopMeetingEndTests.swift:342-375`): the question is withdrawn, every track is cut back to 15 s (240 000 frames at 16 kHz), and a later tap on the withdrawn question changes nothing (still one job). After "Keep recording" (answered at 20 s) a stop by hand at 30 s keeps every track whole (480 000 frames) and writes no `recording_cut` line.
- [ ] Both orders between the same two polls (question open; inside one `onTick` the test taps once, advances the virtual clock with `await h.clock.sleep(for: 0.1)`, then taps again, so the two taps carry distinct times and the comparison stays strict `<`): Keep then Stop keeps every track whole; Stop then Keep cuts back to 15 s. Two `stopDetectedRecording()` calls with a Keep between them still cut (the first request's stamp counts).
- [ ] A recorder that starts but throws on stop (a `MockRecorder` with no mix path), stopped by hand while the signal stays, through `start()`: the loop enters `.error` with `lastError` set, no job is enqueued, the loop returns to `.watching`, and over at least five further polls the still-active app is not recorded again.
- [ ] `stopDetectedRecording()` returns false and changes nothing while the loop is idle, watching without a recording, or recording a manual microphone recording (which keeps running). A request accepted while capture is starting, followed by a recorder start that throws, does not end the next recording.
- [ ] Through `start()` with a per-app scripted detector: Teams recorded, stopped by hand while its signal stays → over at least five further polls no recorder start and no "Record … meeting?" prompt (also for an app that asks first); one poll without the signal writes `redetect_hold_released app=Microsoft Teams`, and when the signal returns Teams is recorded again. Zoom is detected and recorded while Teams is held; Teams held, then Zoom recorded and stopped by hand → both held, Zoom's signal gone releases only Zoom; `stop()` then `start()` with Teams still active records Teams again.
- [ ] Record-only mode: a detected meeting stopped by hand writes its WAVs and a sidecar whose `trigger` is `auto`, and no job.
- [ ] `WatchLoop.swift` stays under 600 lines.
- [ ] Focused run green, read from the log file: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "RedetectionHolds|WatchLoop|RecordOnly|MeetingDetector|PowerAssertion" > /private/tmp/mt-gh94-t1.log 2>&1; echo "exit=$?"` (never pipe the run into tail/head/grep).
- [ ] `PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh` reports 0 violations, and `./scripts/pre-push.sh` (release build) is clean.
## Done summary
The watch loop can now end a detected meeting's recording by hand. `WatchLoop.stopDetectedRecording()` parks a timestamped request that the meeting-end wait acts on at its next poll, through the same stop, cut and enqueue as every other meeting end. The stopped app is then held out of detection (`RedetectionHolds`) until one watching poll finds its signal gone. No UI yet (task .2 wires the menu).

Integrated onto feat/gh-94-stop-detected-recording as 6f719cef (per-app re-detection holds) and 70ebb830 (stop a detected meeting's recording by hand); base f0db8ca5. Worker commits b3256759/e12c3ffd on wave/gh-94.1 were cherry-picked unchanged.

stage: impl-review - ran [21:32:50..21:38:10] SHIP, 0 findings, 3 draws (correctness, contracts, integration) all SHIP; receipt /tmp/impl-review-receipt-846594bd1b60-gh-94-stop-a-detected-meeting-recording-by.1.json (model: codex gpt-5.6-sol xhigh)
stage: wave-join - ran (cherry-pick of 2 commits, no collision)

Tier: session (jev-unavailable(no_key)); explicit invocation: opus at xhigh; actual model: claude-opus-5-5 (host-reported model id; effort not exposed by the host)

Gates (logs under /private/tmp)
- Spec Quick command in the worker's workspace (`mt-gh94-tests.log`) exit 0, 176 tests (163 + 13 new), 0 failures.
- Conductor's integrated verify on the target (`mt-gh94-verify-t1.log`) exit 0, 176 tests.
- Task acceptance command (`mt-gh94-t1.log`) exit 1, 284 tests. The only failures are the 5 WatchLoopE2ETests that need a downloaded WhisperKit model and fail under the fresh CFFIXED_USER_HOME, identically before the change (`mt-gh94-t1-baseline.log`). The other 279 pass, including all 13 new tests and all 13 WatchLoopMeetingEndTests (unchanged). Accepted as environmental per the repository's verification notes; CI is the gate for those.
- `./scripts/lint.sh` with the pinned tools exit 0, 0 violations, 0 files to format.
- `./scripts/pre-push.sh` exit 0, release build with 0 warnings.
- `WatchLoop.swift` is 588 lines, so `cleanTitle`/`transcriberState` stayed in place and `WatchLoopState.swift` is untouched.
- Mutation check: dropping the answer-before-stop filter turned "Stop then Keep" and "Stop, Keep, Stop" red; dropping the request clear in `handleMeeting` let a stale request end the next recording at 0 s. Both reverted byte-identical (`mt-gh94-t1-mutant.log`).
- Not run: CI's `swiftlint analyze` (needs a clean xcodebuild).

Tests per requirement (Tests/WatchLoopStopByHandTests.swift unless noted)
- R2: testAStopByHandEndsAtTheNextPollAndKeepsTheWholeRecording, testRecordOnlyWritesTheStoppedMeetingWithAnAutoTrigger. Errors: testARecorderThatFailsToStopReportsTheErrorAndTheAppStaysHeld, testAStopIsRefusedWhenNoDetectedMeetingRecords, testARequestMadeWhileCaptureStartsDoesNotEndTheNextRecording.
- R3: testAStopByHandDuringTheQuestionWithdrawsItAndCutsBack, testOnlyAKeepRecordingTappedBeforeTheStopKeepsTheWholeRecording (Keep at 20 s, Keep then Stop, Stop then Keep, Stop Keep Stop).
- R4: testAStoppedAppIsHeldUntilItsSignalHasGoneOnce, testHoldsArePerAppAndStopWatchingDiscardsThem, plus Tests/RedetectionHoldsTests.swift (4 tests).
- R5: exact notice lines asserted in the R2 and recorder-failure tests, the release line in both hold tests.

Decisions (worker, rule 6 unless noted)
- `RedetectionHolds.hold` keeps the first meeting when an app is held again; all three detectors' `isMeetingActive` key on `pattern.appName`, so the choice cannot change when a hold is released.
- The same-poll tap tests tap at t = 30 s: a stop at 20.1 s with 30 s tracks makes `RecordingCut.keptSeconds` follow the audio, so only a stop at the tracks' end gives the 15 s cut the acceptance names.
- The hold tests run through `start()` with event waits and the virtual clock as the poll counter, because an asking app's consent prompt task can finish one poll later depending on scheduling.
- The approved-consent branch skips a held app as the task asks; that guard has no test because no reachable path leads to it today (a held app is excluded from `checkOnce`, so it can never get a prompt or an approval).
- Test MARK comments carry no spec R-ids; this code goes to the original project's readers.

Open for later tasks (integration notes in the run notes dir, gh-94.1-integration.md): task .3's anchor `WatchLoop.swift:396-400` now sits at about 404-408, and the file has 11 lines left before the 600-line lint cap.

stage: plan-sync - skipped(config: planSync.enabled=false)
## Evidence
- Commits: 6f719cefce31ce33a5078dd1fc6b36027e9e234c, 70ebb830d011546374a3acaf1ed3413d8b76e5d9
- Tests: worker (wave/gh-94.1): cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "RedetectionHolds|WatchLoopStopByHand|WatchLoopMeetingEnd|WatchingControllerStopRecording|WatchingControllerRecordControl|MenuBarView|RecordActionPayload|RPCRecordStatus|DebugRPCServerIntegration" > /private/tmp/mt-gh94-tests.log 2>&1 -> exit 0, 176 tests (163 baseline + 13 new), 0 failures, worker (wave/gh-94.1): cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "RedetectionHolds|WatchLoop|RecordOnly|MeetingDetector|PowerAssertion" > /private/tmp/mt-gh94-t1.log 2>&1 -> exit 1, 284 tests; the only failures are the 5 WatchLoopE2ETests model-download tests (modelNotLoaded under the fresh CFFIXED_USER_HOME) that failed identically before any edit (/private/tmp/mt-gh94-t1-baseline.log, exit 1, 271 tests); 279 pass incl. all 13 new tests and all 13 WatchLoopMeetingEndTests, worker (wave/gh-94.1): PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh > /private/tmp/mt-gh94-t1-lint-final.log 2>&1 -> exit 0, 0 violations in 705 files, 0 files need formatting, worker (wave/gh-94.1): ./scripts/pre-push.sh > /private/tmp/mt-gh94-t1-prepush.log 2>&1 -> exit 0, release build passed, 0 warnings, conductor integrated verify (feat/gh-94-stop-detected-recording @ 70ebb830): cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "RedetectionHolds|WatchLoopStopByHand|WatchLoopMeetingEnd|WatchingControllerStopRecording|WatchingControllerRecordControl|MenuBarView|RecordActionPayload|RPCRecordStatus|DebugRPCServerIntegration" > /private/tmp/mt-gh94-verify-t1.log 2>&1 -> exit 0, 176 tests, impl-review receipt: /tmp/impl-review-receipt-846594bd1b60-gh-94-stop-a-detected-meeting-recording-by.1.json -> SHIP (codex gpt-5.6-sol xhigh, 3 draws: correctness/contracts/integration all SHIP, 0 findings)
- PRs: