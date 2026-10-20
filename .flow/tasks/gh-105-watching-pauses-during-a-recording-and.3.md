---
satisfies: [R4, R5, R6, R7]
---
# gh-105-watching-pauses-during-a-recording-and.3 Automation API: cancel the resume on stop, answer after it, and document the behaviour

## Description
The automation API part (R4, R5) and the docs for the whole spec. A `/v1/watch` stop during a manual recording cancels the pending resume; `/v1/record` stop and failed start answer after the resume ran; the old API-only restore after a failed microphone start is removed in favour of task .2's resume (spec A3, A6).

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchingController+WatchControl.swift`, `app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift`, `app/MeetingTranscriber/Tests/WatchingControllerResumeWatchingTests.swift`, `app/MeetingTranscriber/Tests/WatchingControllerRecordControlTests.swift`, `docs/automation-api.md`, `docs/stream-deck.md`, `docs/architecture-macos.md`
**Touches:** [app/MeetingTranscriber/Sources/WatchingController+WatchControl.swift, app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift, app/MeetingTranscriber/Tests/WatchingControllerResumeWatchingTests.swift, app/MeetingTranscriber/Tests/WatchingControllerRecordControlTests.swift, docs/automation-api.md, docs/stream-deck.md, docs/architecture-macos.md]

### Approach
- `stopWatching()` (`WatchingController+WatchControl.swift:47-52`): clear the pending resume BEFORE the `isWatching` guard, so a stop during a manual recording (which returns `.unchanged`) cancels it; write one diagnostic line `watch_resume_cancelled` when there was one to cancel (R7, same log path as task .2's failure line). `start` and a `toggle` resolving to a start keep returning `.blocked` (409) during a manual recording.
- `applyRecordStart` (`WatchingController+RecordControl.swift:73-95`): remove `rearmWatching` (`:97-106`) and its two calls; task .2's failed-start resume covers it. Await `joinResume()` before returning `.refused`/`.failed`, so the answer arrives with watching already back.
- `applyRecordStop` (`:115-120`) and `applyRecordStopAny` (`:130-140`): when they stopped a manual recording, await `joinResume()` before answering. `applyRecordStop` is synchronous today; make it `async` only if needed and keep the outcome mapping and codes unchanged.
- Docs: `docs/automation-api.md` `/v1/watch` section (`:230-273`, the 200 bullet at `:258-261`): watching resumes after a manual recording when it was on before; a `stop` sent during the recording cancels that and still answers 200. `/v1/record` (`:305-340`): stop and failed start answer once watching is back. `docs/stream-deck.md` (`:126-175`): the same two facts where stop-watching keys are described. `docs/architecture-macos.md`: rows for `WatchLoop+ResumeHold.swift` beside the WatchLoop rows (`:136-139`) and `WatchingController+ResumeWatching.swift` beside the other `WatchingController+…` rows (`:213-217`). Do not edit `CLAUDE.md` or `AGENTS.md` (fork rule).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift` — start/stop outcomes and the rearm
- `app/MeetingTranscriber/Sources/WatchingController+WatchControl.swift`
- `app/MeetingTranscriber/Tests/WatchingControllerRecordControlTests.swift:150-200` — `testARefusedStartPutsMeetingWatchingBack` and neighbours
- `docs/automation-api.md:230-340`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/DebugRPCServerIntegrationTests.swift:1108-1210` — `/v1/watch` route tests (closure-injected; they need no change)

### Key context
- The `/v1/watch` route tests inject closures and never reach the real controller, so the cancel behaviour is pinned in controller tests, not there.

## Acceptance
- [ ] Controller tests: watching on, manual recording running, `stopWatching()` returns `.unchanged`; after the recording ends, `isWatching` stays false and `watch_resume_cancelled` was logged once. Without the stop, it resumes (task .2 behaviour unchanged).
- [ ] `startWatching()` during a manual recording still returns `.blocked`.
- [ ] `applyRecordAction(.stop)` of a microphone-only recording and `applyRecordStopAny()` of a manual app recording return their usual outcomes with `isWatching` already true when they return (watching was on before).
- [ ] `WatchingControllerRecordControlTests`: the refused/failed-start cases still end with watching back on when the call returns, now through the shared resume; no `rearmWatching` remains (`grep -rn rearmWatching app/MeetingTranscriber/Sources` finds nothing). Any test changed is named in the done summary with the reason (changed mechanism, A3).
- [ ] Docs updated as listed; `DebugRPCServerIntegrationTests` pass unchanged.
- [ ] Focused run green, read from the log file: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "WatchingController|DebugRPCServerIntegration" > /private/tmp/mt-gh105-t3.log 2>&1; echo "exit=$?"`.
- [ ] Lint 0 violations, and `./scripts/pre-push.sh --with-appstore` is clean.

## Done summary
A `/v1/watch` stop sent while a manual recording runs now cancels the pending resume, so watching stays off after that recording, and writes one `watch_resume_cancelled` line. A `/v1/record` stop of a manual recording, and a start that was refused or failed, now answer only after the shared resume has run. The API's own restore after a failed microphone start (`rearmWatching`) is gone, and the three docs describe the new behaviour.

How it works.
- `stopWatching()` (`WatchingController+WatchControl.swift`): after its `joinStart()` and before the `isWatching` guard, it clears `resumeWatchingPending` and writes `watch_resume_cancelled` through `diagnostics.notice`, only when an intent was pending. A stop during a manual recording still returns `.unchanged` (200). `startWatching()` and a `toggle` that resolves to a start are untouched and keep returning `.blocked` (409).
- `applyRecordStart` (`WatchingController+RecordControl.swift`): `wasWatching`, `rearmWatching` and its two calls are removed. The `.permissionRefused` and `.failed` arms `await joinResume()` before they return `.refused` / `.failed`. The resume itself is the one task .2 schedules from `beginManualRecording`'s task.
- `applyRecordStop` is now `async`. It computes the verdict on the stopped loop, then awaits `joinResume()`, then returns the verdict. `applyRecordStopAny` does the same when the stopped recording was manual. A detected meeting keeps watching, so it has no resume to wait for. The outcome mapping and codes are unchanged, and the join's own result is ignored.
- Docs. `docs/automation-api.md`: a "Watching during a manual recording" paragraph under `POST /v1/watch`, an amended 200 bullet, and a paragraph under `POST /v1/record` saying the answer waits for the resume. The two stale Notes bullets ("a refused start puts watching back, a successful one does not" and "stopping does not turn it back on") are replaced by one accurate bullet. `docs/stream-deck.md`: the two facts below the Stop Meeting Watching shortcut, plus a note in "Start and stop beat toggle" that a toggle during such a recording resolves to a refused start. `docs/architecture-macos.md`: rows for `WatchLoop+ResumeHold.swift`, `WatchingController+ResumeWatching.swift` and `WatchingController+LoopFactory.swift`. `CLAUDE.md` and `AGENTS.md` are untouched.

Tests (new file `app/MeetingTranscriber/Tests/WatchingControllerResumeCancelTests.swift`, 5 tests, with its own private `shutDown`).
- `testAWatchStopDuringAManualRecordingCancelsTheResume`: watching on, then a microphone recording. `stopWatching()` returns `.unchanged`, and a repeat through `applyWatchAction(.stop)` returns `.unchanged`. After the recording ends: `isWatching` false, no watch loop, and exactly one `watch_resume_cancelled` line (the repeat had nothing left to cancel).
- `testAWatchStartDuringAManualRecordingIsBlockedAndKeepsTheResume`: runs over `.start` and `.toggle`. Both return `.blocked`, watching resumes after the recording, and no cancel line is written.
- `testARecordStopOfAMicrophoneRecordingAnswersWithWatchingBack`: `applyRecordAction(.stop)` returns `.changed`, and `isWatching` is true when it returns.
- `testAnAnyScopeStopOfAnAppRecordingAnswersWithWatchingBack`: `applyRecordStopAny()` of an app recording returns `.changed`, and `isWatching` is true when it returns.
- `testAFailedRecordStartAnswersWithWatchingBack`: with a `ThrowingRecorder`, the start returns `.failed` and `isWatching` is true. The refused (412) arm stays `WatchingControllerRecordControlTests.testARefusedStartPutsMeetingWatchingBack`.
- Red before the fix (measured, `/private/tmp/mt-gh105/t3-red.log`): the cancel test failed on `isWatching`, the watch loop and the missing line, and both stop tests failed on `isWatching`. The start-blocked and failed-start tests passed: they guard behaviour that already held. The red run used an earlier revision of the file in which `shutDown` was shared with the resume tests. The test bodies were identical.
- Limit (measured by mutation, `/private/tmp/mt-gh105/t3-mutation.log`): with the `joinResume()` removed from the refused and failed arms, `WatchingControllerResumeCancel|WatchingControllerRecordControl` still passed (26 tests). The resume's watch start finishes in the same main-actor turn in which the failed start's task ends, before the API's own 50 ms poll wakes, so no reachable test state separates that join from scheduling. The tests pin the end state the API promises. The stop joins are pinned red to green.

Tests changed.
- `WatchingControllerRecordControlTests.testARefusedStartPutsMeetingWatchingBack`: comment only. "without the re-arm" now names the shared resume and says the answer waits for it, because the mechanism changed (A3). Its assertions are unchanged, and it passes through the shared resume.
- `WatchingControllerResumeWatchingTests.swift` is unchanged. Making its `shutDown` internal was tried and reverted: SwiftLint's `test_case_accessibility` forbids non-private members in a test case.

Gates (all read from log files).
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "WatchingController|DebugRPCServerIntegration" > /private/tmp/mt-gh105-t3.log 2>&1` gave exit=0, 169 tests, 0 failed, 0 `error:` lines, on HEAD 9bbb5c36. That covers DebugRPCServerIntegrationTests (74, unchanged), RecordControl (21), ResumeWatching (15), ResumeCancel (5) and the other WatchingController suites.
- `PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh` gave exit=0, 0 violations in 901 files, and 0/922 files need formatting.
- `./scripts/pre-push.sh --with-appstore > /private/tmp/mt-gh105/t3-prepush.log 2>&1` gave exit=0. The release build, the helper build, the helper tests (21 executed, 3 skipped, 0 failures) and the App Store release build all passed. All 153 warnings come from the local model helper's dependencies (151 mlx-swift, 1 lex.h, 1 local-llm-helper), none from the app.
- `grep -rn rearmWatching app/MeetingTranscriber/Sources` finds nothing (rc=1).

baseline: green via handoff (c176d762: the conductor's focused run of `WatchingController|WatchLoopResumeHold|WatchLoopStopByHand|ManualRecording|MenuBarView|SignallingMeetings` exit 0, 239 tests, 0 failures; lint 0 violations in 900 files). The first lint run after the edit found 2 violations in this task's own changes, both fixed before commit.

Choices:
- DECIDED: the cancel sits after `stopWatching`'s `joinStart()` and before the `isWatching` guard · task Approach ("clear the pending resume BEFORE the `isWatching` guard"). A start that settles during the join has already installed its loop and consumed the intent, the stop then ends that loop, and no cancel line is written. A stop whose join expires (503) cancels nothing. The resume waits on the same unsettled start, gives up on it and drops the intent with its own `watch_resume_failed` line, so one resume never writes both lines (inferred from the code).
- DECIDED: the line is exactly `watch_resume_cancelled`, at notice level through `diagnostics` · task Approach names the line. R7 and task .2's failure line set the log path and level.
- DECIDED: only `.permissionRefused` and `.failed` await the resume, not `.blockedByActiveRecording` · task Approach ("before returning `.refused`/`.failed`"). A start blocked by an active recording took nothing over and has no resume to wait for.
- DECIDED: the joins' own results are ignored, and the answer keeps its outcome · task Approach ("keep the outcome mapping and codes unchanged"). The outcome describes the recording, and `GET /v1/watch` reports watching.
- DECIDED: the verdict is computed before the join · the verdict reads the stopped loop, which the resume never touches. Computing it first keeps the answer about the stop itself.
- DECIDED: `applyRecordStopAny` awaits the resume only for a manual recording · task Approach ("when they stopped a manual recording"). A detected meeting's loop keeps watching (gh-94).
- DECIDED: the two stale Notes bullets in `docs/automation-api.md` are rewritten into one · they contradicted R2 and R5 after this change ("anything your change breaks").
- DECIDED: new tests live in their own file with a private copy of the six-line teardown · conductor rule (new file for the cancel and ordering cases) and SwiftLint `test_case_accessibility`, which blocks sharing the existing helper from inside its test class.

Follow-ups (not fixed):
- The menu's Stop Watching (`toggleWatching`'s stop branch) still does not clear a pending intent. This was already noted by task .2. The menu hides the toggle during a recording (task .4), so only `/v1/watch` can cancel.
- `docs/architecture-macos.md` still has no row for `WatchLoop+Display.swift` (task .2). Its `RedetectionHolds.swift` row still names `AppMeetingPattern.appName`, where the identity is now `identityKey`. Both predate this task.
- Worst case, the resume join can add one `startJoinTimeout` (20 s) to a `/v1/record` answer, on top of the entry join. This needs a watch start parked on a microphone prompt in the instant between the stop and the resume, which no test reaches. The common case costs one 50 ms poll.

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)
stage: impl-review - ran [2026-10-20T13:21Z..2026-10-20T13:29Z] SHIP, 1 round, 3 draws (correctness, contracts, integration) all SHIP, one kept P3 docs finding (automation-api.md promised watching back after every record stop, contradicting the /v1/watch stop cancellation) fixed in a6d83637, receipt /tmp/impl-review-receipt-0a7d6728fcc1-gh-105-watching-pauses-during-a-recording-and.3.json (model: gpt-6-astra:xhigh)
stage: plan-sync - skipped(config: planSync.enabled=false)
Integrated onto the spec branch by fast-forward (de45f8f9, 55bde681, 1881085e, 9bbb5c36 unchanged); focused integrated verify at a6d83637: WatchingController, DebugRPCServerIntegration, WatchLoopResumeHold, MenuBarView and SignallingMeetings exit=0, 250 tests, 0 failures (/private/tmp/mt-gh105/verify-t3.log), lint 0 violations in 901 files, grep rearmWatching in Sources empty.
## Evidence
- Commits: de45f8f977961d5aba68cea3ecf88cca2a0ae7d9, 55bde6817280a1796b4dae02a4c7c55a6707b41a, 1881085e055e74b950d997ffb119909deb37230e, 9bbb5c363daa51788afb5b5a850ff8765da8e313, a6d836377f99f938c9fb996f93685837fcb5a760
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "WatchingController|DebugRPCServerIntegration" > /private/tmp/mt-gh105-t3.log 2>&1 -> exit=0, 169 tests, 0 failed (HEAD 9bbb5c36), PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh -> exit=0, 0 violations in 901 files, 0/922 files require formatting, ./scripts/pre-push.sh --with-appstore > /private/tmp/mt-gh105/t3-prepush.log 2>&1 -> exit=0 (release, helper build, helper tests 21 executed 3 skipped 0 failures, App Store release; 153 warnings all from local model helper deps), grep -rn rearmWatching app/MeetingTranscriber/Sources -> no match (rc=1), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "WatchingController|DebugRPCServerIntegration|WatchLoopResumeHold|MenuBarView|SignallingMeetings" > /private/tmp/mt-gh105/verify-t3.log 2>&1 (integrated spec branch at a6d83637: exit=0, 250 tests, 0 failures); PATH=lint-tools ./scripts/lint.sh (0 violations in 901 files), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "WatchingController|DebugRPCServerIntegration|WatchLoopResumeHold|MenuBarView|SignallingMeetings" (exit=0, 250 tests); PATH=lint-tools ./scripts/lint.sh (0 violations); grep -rn rearmWatching app/MeetingTranscriber/Sources (empty)
- PRs: