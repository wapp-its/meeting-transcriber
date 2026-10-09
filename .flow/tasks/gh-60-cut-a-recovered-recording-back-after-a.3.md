---
satisfies: [R1, R3, R4]
---
# gh-60-cut-a-recovered-recording-back-after-a.3 Store the cut when the meeting-end question opens and settle it on every end

## Description
The watch loop decides when: store before the question is posted; clear when the question is taken back; clear a settled question's cut before the recorder stops; for a cut-carrying stop, record the resolved cut before any track changes and clear after the cut; never clear on a cut-carrying stop that failed. Logs the write and removal failures, and carries the docs for the whole spec. See spec Architecture (who writes and removes it, the resolved cut), Edge Cases, R1, R3, R4.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift`, `app/MeetingTranscriber/Sources/WatchLoop.swift`, `app/MeetingTranscriber/Tests/WatchLoopMeetingEndTests.swift`, `docs/architecture-macos.md`
**Touches:** [app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Tests/WatchLoopMeetingEndTests.swift, docs/architecture-macos.md]

### Approach
- Store in the `.askToEnd` arm (`WatchLoop+MeetingEnd.swift:66-68`) BEFORE `askToEnd(meeting)` posts the notification, through the active recorder (`activeRecorder`, `WatchLoop.swift:30`, set at `:418`) with `pending.cutAt`, `pending.deadline` and the recording's start on the loop clock (`recordingStartedAt`, `WatchLoop.swift:421`; pass it into `waitForMeetingEnd` or keep it on the loop, implementer's call; the direct `waitForMeetingEnd(meeting)` calls in tests run without a recorder and store nothing). Failure → `diagnostics.warning("pending_cut_write_failed domain=<d> code=<c> published=<true|false>")` (task 2's error says which), countdown carries on.
- Clear in the `.withdrawQuestion` arm (`:70-72`, Keep or a returning signal), unconditionally, also when the store had failed: a failed store may have published its record. NOT in the `defer` at `:41`: that also runs on the cut-carrying exits.
- In `handleMeeting` (`WatchLoop.swift:439-449`): when `waitForMeetingEnd` returns no cut (a Keep just before Stop Watching via `cutWhenWatchingStops`, `WatchLoopEndPolicy.swift:170-176`; the cap together with a Keep or a returning signal via `capStop`, `:182-201`; a stop by hand with no question open or after a Keep; or no question at all), clear BEFORE `recorder.stop()`. Since gh-94 a stop by hand (menu or automation API) rides the same exit: `takeStopByHandRequest()` at the top of each `waitForMeetingEnd` poll (`WatchLoop+MeetingEnd.swift:47-55`) returns `cutWhenWatchingStops`, so it carries a cut exactly like Stop Watching while the question is open and none otherwise, and it skips the `.withdrawQuestion` arm, which is why the clear lives in `handleMeeting`. With a cut: `recorder.stop()`, then `cutBack`, then clear, before `enqueueRecording`. A throwing `recorder.stop()` leaves the function before the clear (task 2 releases the hold).
- In `cutBack` (`WatchLoop+MeetingEnd.swift:95-128`; since gh-4 it also calls `RecordingCut.remixBalanced` after a successful apply, `:114-121`, which stays after the cut): after `keptSeconds` is computed and before `RecordingCut.apply`, call `recordPendingCutResolution(keptSeconds:captureEndedAt: stoppedAt)` on the active recorder; a failure logs `pending_cut_write_failed` and the cut proceeds (spec A7).
- Removal failure: `diagnostics.warning("pending_cut_remove_failed domain=<d> code=<c> emptied=<true|false>")`, no path.
- Keep `WatchLoop.swift` additions to calls of helpers that live in `WatchLoop+MeetingEnd.swift`: the file is at 589 lines against SwiftLint's 600-line warning.
- `docs/architecture-macos.md`: rows for `PendingRecordingCut.swift` and `RecoveredCut.swift` in the file tables (near `WatchLoopEndPolicy.swift` at `:140` and the recovery rows at `:172`/`:190`), and one sentence beside the `WavHeaderRepair` row (`:220`; the doc has no crash-recovery paragraph, the earlier `:424` anchor was the #693 start-order text) that a stored meeting-end cut is applied before a recovered recording is queued. Do not edit `CLAUDE.md`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift` — the question lifecycle, the defer, cutBack
- `app/MeetingTranscriber/Sources/WatchLoop.swift:399-458` — handleMeeting's start, wait, stop, cut, enqueue
- `app/MeetingTranscriber/Sources/WatchLoopEndPolicy.swift` — which exits carry a cut (`ask`, `capStop`, `cutWhenWatchingStops`)
- `app/MeetingTranscriber/Tests/WatchLoopMeetingEndTests.swift` — the harness (`makeLoop`, injected clock, `RecordingNotifier`, `RecordingDiagnostics`) and the countdown scenarios to extend (`makeLoop` at `:45`; unanswered `:187`, failed cut `:232`, stop now `:249`, keep `:293`, stop watching `:342`, keep before stop `:377`, cap `:404`)

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/MockRecorder.swift` — the ordered call log and failure switches from task 2

### Key context
- Assert order on one log: the store comes before the notification post (compare against `RecordingNotifier`'s record), the clear before `stop` for a stop without a cut, and the resolution while the WAV fixture tracks are still uncut (task 2's closure hook).
## Acceptance
- [ ] Question opens: the stored cut carries the policy's `cutAt` and `deadline` and the recording's start, and is stored before the notification is posted.
- [ ] A store failure logs `pending_cut_write_failed … published=…` and the countdown still ends the recording cut back as before.
- [ ] After a store that failed with its record published, "Keep recording" and a returning signal still call the clear (MockRecorder log), so the record never outlives the settled question.
- [ ] A returning signal clears it at the withdraw; a later loss stores a fresh one with the new cut point.
- [ ] "Keep recording" clears it at once; the recording later ends uncut (cap or Stop Watching) with no stored cut left.
- [ ] Keep answered just before Stop Watching, and the cap reached on the poll that sees a Keep: the stored cut is cleared before `recorder.stop()`; with a throwing `stop()` the clear has still happened.
- [ ] Countdown expiry, "Stop now", Stop Watching during the question and the cap during the question: nothing is cleared before `recorder.stop()`; the resolution (`keptSeconds` equal to the seconds the tracks are cut to, `captureEndedAt` = the stop time) is recorded while the tracks are still uncut; after the cut the stored cut is cleared exactly once.
- [ ] A failed cut still clears the stored cut (recording processed uncut, as in gh-54); a failed resolution write logs and the cut still happens.
- [ ] A throwing `recorder.stop()` on a cut-carrying stop clears nothing.
- [ ] A removal failure logs `pending_cut_remove_failed … emptied=…` with no path.
- [ ] Manual recordings never store a cut.
- [ ] `docs/architecture-macos.md` names the new files and the recovery step; `CLAUDE.md` untouched; `WatchLoop.swift` stays under 600 lines; focused tests and lint pass.
## Done summary
A recording the app dies with while the meeting-end question is open now has its cut point on disk, so the next launch's recovery cuts it back as the countdown would have. The watch loop stores the cut before the question is posted, clears it when Keep recording or a returning signal settles the question, clears it before the recorder stops when the stop carries no cut, and on a stop that cuts it records the resolved cut before any track changes and clears it after the cut. A throwing stop on a cut-carrying end clears nothing, so the recorder hands the cut to recovery with the marker.

stage: impl-review - ran [2026-10-09T02:29:07Z..2026-10-09T02:33:25Z] (codex gpt-5.6-sol xhigh per receipt; round 1 three draws correctness/contracts/integration, all SHIP with zero findings; finalized with an empty --merge-plan; validator not run because it runs only on NEEDS_WORK; reviewer ran with CODEX_SANDBOX=workspace-write per the owner's standing setting and wrote nothing outside .flow/)

Tier: session (jev-unavailable(no_key)); explicit invocation: opus at xhigh; actual model: claude-opus-5-5 (host metadata)

baseline: green via handoff (verified at 4ab0a4d9 by task .2; only .flow/ changed since); lint 0 violations in 714 files before any edit

### Tests per acceptance criterion

All in `app/MeetingTranscriber/Tests/WatchLoopMeetingEndTests.swift`. Every new test reads `MockRecorder.calls`, the ordered recorder log from task .2.

- Question opens, stored before the post, with the policy's `cutAt` and `deadline` and the recording's start: `testAnEndOutOfTheQuestionResolvesTheStoredCutBeforeCuttingAndClearsItAfter`. A test-local `StoreOrderRecorder` notes how many questions had gone out at each store.
- A store failure logs `pending_cut_write_failed … published=false` and the countdown still cuts back to 10 s: `testAFailedWriteOrRemovalOfTheStoredCutIsLoggedAndTheRecordingStillCut` (row 1).
- A store that failed with its record published is still cleared by Keep and by a returning signal: `testASettledQuestionClearsItsStoredCutAtOnceEvenAfterAFailedStore` (store-failed rows).
- A returning signal clears at the withdraw and a later loss stores a fresh cut at 40 s: `testALaterLossStoresAFreshCutAfterAReturningSignalClearedTheFirst`.
- Keep recording clears at once and the cap later ends the recording uncut: `testASettledQuestionClearsItsStoredCutAtOnceEvenAfterAFailedStore` (store-ok rows).
- Keep just before Stop Watching clears before `stop()`: `testKeepRecordingAnsweredJustBeforeStopWatchingKeepsTheRecordingUncut` (extended). The cap on the poll that sees a Keep, and a stop by hand with no question open, clear before `stop()` with a completing and with a throwing stop: `testAStopWithoutACutClearsTheStoredCutBeforeTheRecorderStops`.
- Countdown expiry, Stop now, the cap and a stop by hand during the question clear nothing before `stop()`, record `keptSeconds` equal to the seconds the tracks are cut to and `captureEndedAt` equal to the stop time while every track is still 480,000 frames, and clear exactly once after the cut: `testAnEndOutOfTheQuestionResolvesTheStoredCutBeforeCuttingAndClearsItAfter`. Stop Watching during the question: `testStopWatchingDuringTheQuestionEndsCutBackAndWithdraws` (extended).
- A failed cut still clears: `testAFailedCutProcessesTheRecordingUncutAndLogsIt` (extended). A failed resolution write logs `published=true` and the cut still happens: `testAFailedWriteOrRemovalOfTheStoredCutIsLoggedAndTheRecordingStillCut` (row 2).
- A throwing `stop()` on a cut-carrying end clears nothing: `testACutCarryingStopThatThrowsClearsNothing`.
- A removal failure logs `pending_cut_remove_failed … emptied=…` with no path, for `removedNotSynced`, `emptied` and `failed`: `testAFailedWriteOrRemovalOfTheStoredCutIsLoggedAndTheRecordingStillCut` (rows 3 to 5, exact line equality).
- Manual recordings never store a cut: `testAManualRecordingStoresNoCut`.
- `docs/architecture-macos.md` names `PendingRecordingCut.swift` and `RecoveredCut.swift` and says the staged recovery applies a stored cut before a recovered recording is queued. `CLAUDE.md` is untouched. `WatchLoop.swift` is 591 lines.

Mutation-checked. Each of these edits turns the suite red, and the tree was restored after each: the store moved after the post, the withdraw-arm clear removed, the pre-stop clear removed, the pre-stop clear moved after `stop()`, the resolution moved after the cut, the post-cut clear read from `activeRecorder` (caught by the Stop Watching test), a clear before every stop, the `emptied=true` flag lost, and the `published=true` flag lost.

Verification on the final tree (f8e765f7):
- `swift test --parallel --filter 'WatchLoop|DualSourceRecorder|RecordOnly|PendingRecordingCut|RecoveredCut|StagedRecovery|RecordingCut'` with `CFFIXED_USER_HOME=/private/tmp/mt-gh60-home`: 289 tests ran and 284 passed. The 5 failures are the known environmental `WatchLoopE2ETests` (`modelNotLoaded`, no WhisperKit model under the redirected home), the same 5 task .2 saw. CI is their gate. The spec's Quick filter is a subset of this run, and none of its tests failed.
- `swift test --parallel --filter WatchLoopMeetingEnd`: 20 of 20 passed (13 existing, 7 new).
- `./scripts/lint.sh` with the pinned tools: 0 violations in 714 files.

### Decisions

- **How the recording reaches the wait.** `waitForMeetingEnd(_:storingCutsIn:)` takes an optional `(recorder:, startedAt:)` pair, and `cutBack` and `clearStoredCut(of:)` take the recorder explicitly. The task suggested `activeRecorder`, but `WatchLoop.stop()` (Stop Watching) runs `cleanupManualRecording()`, which sets `activeRecorder = nil` before `handleMeeting` stops and cuts the recording it ends, so the resolution and the clear would have been skipped on that path. Direct `waitForMeetingEnd(meeting)` calls in tests pass nothing and store nothing. Flip at `WatchLoop+MeetingEnd.swift` (the three signatures) and the two call sites in `handleMeeting`.
- **Log lines carry exactly the task's fields.** `pending_cut_write_failed domain=<d> code=<c> published=<b>` serves both the store and the resolution. The two are told apart by the neighbouring lines (the resolution's failure sits right before `recording_cut kept_s=` or `recording_cut_failed`). A non-`PendingCutWriteError` from the store (`RecorderError.notRecording`) logs its own domain and code with `published=false`. The alternative was a `value=cut|resolution` field like task .4's `recovered_cut_store_failed value=`. Flip at `logStoredCutWriteFailure`.
- **Removal outcome mapping.** `removedNotSynced(e)` logs `e` with `emptied=false`, `emptied(unlink)` logs the unlink error with `emptied=true`, and `failed(unlink, _)` logs the unlink error with `emptied=false`, the same error choice as task .4's `recovered_cut_remove_failed`. `removedNotSynced` and `failed` therefore both read `emptied=false`, and both mean the record may survive (an unsynced unlink can revert on power loss). The alternative was an extra `removed=` field. Flip at `clearStoredCut(of:)`.
- **A stop without a cut always clears before `stop()`**, also when no question was ever asked or a Keep already cleared it. The recorder makes that a no-op, and `MockRecorder` logs it, which is why the settled-question tests expect two clears.
- **`file_length` suppressed** at the top of `WatchLoopMeetingEndTests.swift` (662 lines), as in `PipelineQueueTests.swift` and `AppStateTests.swift`. The new tests need the file's private `Harness`, and a new test file is outside this task's Touches. Flip by moving the "The stored cut" extension into its own file and widening `Harness` to file-external access.
- **Reviewer sandbox.** `CODEX_SANDBOX=workspace-write` was exported as the conductor instructed (owner's standing setting). The impl-review skill text says never to set it. The reviewer wrote nothing outside `.flow/`.

### Follow-ups noticed, not fixed

- `WatchLoop.stop()` clears `activeRecorder` for a detected meeting's recording too (through `cleanupManualRecording()`), so AppState's level monitor and anything else reading `activeRecorder` lose the recorder while that recording is still being stopped and cut. This predates the change. This task avoids it by passing the recorder explicitly.
- `WatchLoopMeetingEndTests.swift` is past the 600-line warning. Moving the stored-cut tests into their own file would let the suppression go.
- No user route to a mapped feature changed.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: ff596d85eb4e694e176213c655ab975d70e37342, f8e765f736441e35111a3574269217bab941459d
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh60-home swift test --parallel --filter 'WatchLoop|DualSourceRecorder|RecordOnly|PendingRecordingCut|RecoveredCut|StagedRecovery|RecordingCut' (289 ran, 284 passed; 5 environmental WatchLoopE2ETests modelNotLoaded, CI is their gate), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh60-home swift test --parallel --filter WatchLoopMeetingEnd (20/20 passed), PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh (0 violations in 714 files)
- PRs: