---
satisfies: [R5, R6, R10]
---
# gh-138-local-model-for-protocols-in-the.4 Wire the gate: job identity, recording preemption and cancellation

## Description
Connect the gate from task 3 to everything that can start, stop or cancel a local generation: set the job identity at every call site, defer and preempt on recording start, resume after the recording ends, and route job cancellation and app quit to the helper.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift`, `app/MeetingTranscriber/Sources/PipelineQueue.swift`, `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift`, `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift` (from gh-2), `app/MeetingTranscriber/Sources/WatchingController+LocalModel.swift` (new), `app/MeetingTranscriber/Sources/WatchingController.swift`, `app/MeetingTranscriber/Sources/AppState.swift`, tests
**Touches:** [app/MeetingTranscriber/Sources/PipelineQueue*.swift, app/MeetingTranscriber/Sources/SpeakerNamingSession.swift, app/MeetingTranscriber/Sources/ProtocolRegeneration.swift, app/MeetingTranscriber/Sources/WatchingController*.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Tests/LocalModelGateWiringTests.swift, app/MeetingTranscriber/Tests/LocalModelRecordingPreemptionTests.swift]

### Approach
- Job identity: set the gate's `@TaskLocal` job id around the provider call in `PipelineQueue.generateProtocol` (the choke point for the queue and every `SpeakerNamingSession` path, which call it through the delegate from untracked tasks at `SpeakerNamingSession.swift:172-233`) and in gh-2's `ProtocolRegenerator.run` (its `target.jobID`).
- Recording state: in a new `WatchingController+LocalModel.swift`, hook the existing state-change handler (`WatchingController.swift:548-565`: entering `.recording`, leaving it) and the manual-start window (`manualStartTask != nil`) to tell the gate; a paused recording still counts as recording. Keep `WatchingController.swift` and `WatchLoop.swift` additions minimal, both are near the line limit.
- Gate behaviour: admission waits while a recording runs; recording start terminates the running helper (deferred outcome) within 5 s; the deferred caller waits at the gate and runs again once no recording runs. The job stays in `.generatingProtocol` meanwhile, so an app restart resumes only the protocol stage through the existing `ProtocolResumePolicy`.
- Cancellation: `PipelineQueue.cancelJob` (`PipelineQueue.swift:618-641`) also calls `gate.cancel(jobID:)`, so a naming-triggered generation's helper ends and another job is untouched. App quit: terminate the helper on `willTerminate` (the helper also exits on parent death from task 1).
- One recording-activity signal, true from the start of any recording (detected, manual, microphone-only through `/v1/record`) until it has fully stopped, paused included; the gate and the deferred resumes read only this.
- Deferred jobs resume one at a time in their original order, each through the full start check; a second deferral of the same job notifies nothing new.
- In record-only mode no local generation starts.
- On `willTerminate`, terminate the running helper synchronously (SIGKILL after a short grace); the helper's parent-death exit from task 1 covers a crash.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/PipelineQueue.swift:600-660,950-970` — cancel and processing
- `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift:160-260,540-560` — untracked generation tasks
- `app/MeetingTranscriber/Sources/WatchingController.swift:540-580` — state-change handler
- `app/MeetingTranscriber/Sources/ProtocolResumePolicy.swift:4-44` — restore of an interrupted protocol

**Optional:**
- `app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift` — RPC-started recordings go through the same loop

### Key context
- Flow-next memory: no `await` in `processNext` before the job leaves `.waiting`, nor before the `.generatingProtocol` transition in `resumeProtocolOnly`; test restored jobs through `loadSnapshot()` plus `awaitProcessing()`.
- A deferred run that is re-run must not record the first attempt's outcome over the second (superseded-attempt rule).
## Acceptance
- [ ] Two naming confirmations back to back plus a queued protocol never run two helpers (fake helper counts concurrent instances).
- [ ] Starting a recording during a fake-helper run terminates it within 5 s; the job stays in `.generatingProtocol` and its protocol runs after the recording ends; a protocol due during a recording waits.
- [ ] Cancelling a naming-triggered job ends its helper and leaves another queued job untouched; cancelling a job that does not own the helper leaves the helper running.
- [ ] A job snapshot saved while deferred restores into a protocol-only run.
- [ ] Other providers' behaviour is unchanged (existing pipeline tests pass).
- [ ] A paused recording keeps a due protocol waiting; two jobs deferred by one recording run in their original order afterwards.
## Done summary
Every path that can run the local model (queue, speaker-naming confirm/skip/stale cleanup, restore resume, regeneration) now runs under its job id at the one gate; a recording or record-only mode holds the gate and ends a running helper, the deferred protocol re-asks at once and runs after the recording in its original place while the job stays `.generatingProtocol`; a job cancel reaches only the helper that job owns, and quitting ends the helper before exit.

baseline: green via handoff (verified at 6e59cf6f by task .3; only .flow/ commits since), lint baseline rc=0
stage: impl-review - skipped(policy: parallel-wave - conductor owns the gate)
Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

### Acceptance criteria and their tests

- Two naming confirmations plus a queued protocol never run two helpers: `LocalModelGateWiringTests.testTwoNamingConfirmationsAndAQueuedProtocolNeverRunTwoHelpers` (events strictly start/end three times).
- Recording start ends the helper within 5 s, job stays `.generatingProtocol`, protocol runs after the recording, no failure warning from the interrupted attempt: `LocalModelRecordingPreemptionTests.testRecordingStartEndsTheHelperAndTheProtocolRunsAfterTheRecording`. A protocol due during a recording waits: `testProtocolDueDuringARecordingWaitsForItsEnd`.
- Cancel a naming job: its helper ends and the queued job still gets its protocol: `LocalModelGateWiringTests.testCancellingANamingJobEndsItsHelperAndLeavesTheQueuedJobAlone`. Cancel a job that does not own the helper: it keeps running: `testCancellingAJobThatDoesNotOwnTheHelperLeavesItRunning` (red before the `processingJobID` fix, by mutation).
- Snapshot saved while deferred restores into a protocol-only run (no re-transcription): `LocalModelRecordingPreemptionTests.testSnapshotSavedWhileDeferredRestoresIntoAProtocolOnlyRun`.
- Other providers unchanged: the focused suite (948 tests) passes except 5 `WatchLoopE2ETests` that failed on the WhisperKit model download into a fresh scratch home (before the protocol stage) and pass on rerun (8/8). Non-local generators take the old single call.
- A paused recording keeps a due protocol waiting: `testAManualRecordingHoldsTheGateFromItsStartThroughAPauseUntilItStops` (also pins the manual-start window). Jobs in line keep their order (deferred job, then the one already waiting, then one that arrived during the recording): `testJobsInLineWhenARecordingStartsRunInTheirOriginalOrderAfterIt`.
- Also pinned: detected meeting holds the gate (`testADetectedMeetingHoldsTheGateUntilWatchingStops`), record-only holds it (`testRecordOnlyModeHoldsTheGateWhileItIsOn`), regeneration runs as its meeting's job (`testRegenerationRunsAsItsMeetingsJob`), the quit observer blocks until a SIGTERM-ignoring helper is killed (`testQuitEndsTheRunningHelperBeforeTheAppExits`).

### Decisions

1. Rule 6. The deferred caller waits at the gate, not by polling: `PipelineQueue.generateWaitingOutRecordings` re-asks at once with the same generator; the gate admits nothing while the signal is on and holds the job's place. Only the last attempt's result reaches `generateProtocol` (superseded-attempt rule).
2. Rule 6. Quit grace is the gate's existing `LocalModelLimits.quitGrace` (1 s), then SIGKILL. The observer is registered with `queue: nil` and runs `MainActor.assumeIsolated`, so it completes inside `terminate` before `exit` (the `LivenessMarker` pattern).
3. Rule 6. The recording-activity signal is composed in `WatchingController+LocalModel.swift` (`isRecordingActivity`: `manualStartTask != nil || watchLoop?.state == .recording`, paused included) and pushed synchronously from `didSet` on `watchLoop` and `manualStartTask` and one call in the state-change handler, so a recording ends the helper in the same main-actor turn it starts.
4. Rule 4. Record-only mode holds the gate (`isRecordingActivity || settings.recordOnly`): a local protocol due in record-only mode (an import, a naming confirm) waits in `.generatingProtocol` until the mode is off, and turning it on mid-run ends the helper as deferred. Switch point: `WatchingController.recordingActivityChanged()` in `WatchingController+LocalModel.swift`. Pinning test: `LocalModelRecordingPreemptionTests.testRecordOnlyModeHoldsTheGateWhileItIsOn`.
5. Rule 6. `cancelJob` cancels the queue's processing task only when it runs the cancelled job (`processingJobID`). Before, cancelling a job whose protocol a naming task was writing cancelled whichever job the queue was processing.
6. Rule 6. The queue learns the gate from the `LocalModelProtocolGenerator` it runs (`PipelineController` is outside Touches), set before any await. Every naming path looks the job up and reaches the gate in one main-actor turn, so a cancel either finds no job to run or finds the gate known.
7. Rule 6. No un-cancel for the gate's permanent cancelled set: a cancelled job leaves the queue and writes no finished-job record, so no regeneration target carries its id.
8. Rule 6. Regeneration is not re-asked after a deferral (spec R11: not resumed automatically); the gate frees its held place after `deferredHold`.

### Touches extended

None in the first pass; fix pass 1 adds `WatchLoop.swift` (see below). `SpeakerNamingSession.swift` needed no change: all its paths call `PipelineQueue.generateProtocol`.

### Follow-ups

- Task .5: the "Protocol paused for your recording" notice belongs on the first deferral in `generateWaitingOutRecordings`. With decision 4, a record-only switch-on also ends a helper as `deferredForRecording`; the gate has one hold input, so that notice text would be wrong in that case. Detail: NOTES_DIR `task4-wiring-notes.md`.
- Task .5: `ProtocolRegenerator.run` still maps every provider error, the deferred outcome included, to `generationFailed` (R11 regeneration outcomes).
- The one-line `endLocalModelOnQuit` call in `AppState.init` has no test; the function is pinned on a private NotificationCenter.

### Fix pass 1

Finding (P1): Stop Watching during a detected meeting turned the recording signal off at the click, while the cancelled loop stops the recorder in a later turn, so the gate could admit a waiting local generation during capture finalization. Fixed in d74072e4.

- `WatchLoop.handleMeeting` reports its capture through a new hook, `onMeetingCapture`: true at entry (same turn as the `.recording` update), false from a `defer`, so after `recorder.stop()` and `enqueueRecording` (or on a throw).
- `WatchingController` counts running detected captures (`detectedCapturesRunning`); `isRecordingActivity` is now `manualStartTask != nil || watchLoop?.state == .recording || detectedCapturesRunning > 0`. The `watchLoop` didSet calls `watchLoopChanged()`, which installs the hook on each assigned loop and pushes the signal. This supersedes the signal definition in decision 3 and removes the "accepted gap" doc note. The start push stays synchronous.
- Manual path unchanged: `WatchLoop.stopManualRecording` stops the recorder before the phase leaves `.recording`, and `toggleWatching` refuses to stop a manual loop.
- New test `LocalModelRecordingPreemptionTests.testStopWatchingHoldsTheGateUntilTheMeetingsRecorderHasStopped`: after `toggleWatching()` the recorder has not stopped and the gate has no owner; a probe inside the fake recorder's `stop()` sees the gate still holding; the waiter is admitted after. Mutation (signal without the count): red on exactly those two assertions. The existing detected-meeting test now shares a setup helper with it; its assertions are unchanged.

Decisions:

9. Rule 5. The count lives on the controller, not on the loop: Stop Watching drops the loop, and a loop started meanwhile (Start Watching again) must not clear it. Flip point: `WatchingController.watchLoopChanged()` in `WatchingController+LocalModel.swift`. Pinning test: `testStopWatchingHoldsTheGateUntilTheMeetingsRecorderHasStopped`.

Touches extended: `app/MeetingTranscriber/Sources/WatchLoop.swift` (+4 lines, 599 now): the loop wipes its phase and recorder reference synchronously in `stop()`, so only `handleMeeting` knows when the cancelled capture's recorder has stopped. `WatchingController.swift` is at 600 lines (the cap), one stored property added.

Re-run results (at d74072e4; the focused suite ran before two lint fixes in the new test's assertions, which `LocalModelRecordingPreemptionTests` re-ran after):

- `swift build --build-tests` rc=0; `swift build -Xswiftc -DAPPSTORE` rc=0.
- Focused suite (same filter, fresh scratch home): 949 tests, 5 failed, all `WatchLoopE2ETests` (WhisperKit model download into the fresh home); rerun of that class with the persistent home: 8/8 green.
- `LocalModelRecordingPreemptionTests`: 8/8 green.
- `./scripts/lint.sh` with pinned tools: rc=0, 0 violations, 0 files need formatting.
- Clean `xcodebuild build-for-testing` rc=0, no warnings in touched files; `swiftlint analyze --strict` rc=0, 0 violations in 806 files.


stage: impl-review - ran [21:59:37Z..22:32:52Z] (model: codex gpt-6-astra xhigh; round 1 three draws, all NEEDS_WORK on one shared P1, the recording signal cleared at Stop Watching before the recorder had stopped; the validator pass was not run, the finding was taken as real and fixed; round 2 one reviewer, resumed session, fixed) - SHIP
stage: wave-join - ran (the lane's six commits replayed onto the spec branch by cherry-pick because task .6 had landed first; lane 3ee643fc, 4fabbf78, 876be5c4, fb414bef, 98707b85, d74072e4 became 3f13a754, 9f962ad9, db021c92, 6c57cddd, f01dc3a9, e73813b8; the evidence commit list names the lane SHAs, the range below names the spec-branch ones)
stage: conductor-verify - ran on the integrated spec worktree at e73813b8: swift build rc=0, swift build -Xswiftc -DAPPSTORE rc=0, focused tests rc=0 (568 cases), App Store test variant rc=0 (2 cases)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 3f13a754fb958c3d28701ad56c4a4e92b1aa0420, 9f962ad95d5c7d3e6022e46004b929cc1afa3588, db021c926e6936722f7c16f9e359e69509e7cdb1, 6c57cdddeba430ccd6470e228fc73c8659759363, f01dc3a93c7a8fc04e5f5ef3fdd95e1a5cc5739a, e73813b863611fe8f5729f7ff038a3350f35aa15
- Tests: baseline: green via handoff (verified at 6e59cf6f by task .3; only .flow/ commits since), cd app/MeetingTranscriber && swift build (rc=0, at 98707b85), cd app/MeetingTranscriber && swift build -Xswiftc -DAPPSTORE (rc=0, at 98707b85), cd app/MeetingTranscriber && CFFIXED_USER_HOME="$(mktemp -d)" swift test --parallel --filter 'ProtocolGenerator|PipelineQueue|NotificationManager|OutputSettings|LocalModel|SpeakerNaming|WatchingController|WatchLoop|ProtocolRegenerat' (rc=1, 948 tests, 5 failed, all WatchLoopE2ETests: WhisperKit model download into the fresh scratch home, job state error before the protocol stage; tree = 98707b85 minus one doc-comment reword and one test line), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/mt-flow/home-e2e swift test --filter 'WatchLoopE2ETests' (rc=0, 8 tests, 0 failures, rerun of the failed class with a persistent scratch home), cd app/MeetingTranscriber && CFFIXED_USER_HOME="$(mktemp -d)" swift test --parallel --filter 'LocalModel' (rc=0, 46 tests, at 98707b85), mutation check: 7 source mutations (cancel scope, gate cancel on job cancel, deferral retry, state-change push, manual-start window, record-only hold, regeneration job id), each turned at least one of LocalModelGateWiringTests / LocalModelRecordingPreemptionTests red; sources restored, PATH=<pinned lint tools>:$PATH ./scripts/lint.sh (rc=0, 0/906 files need formatting, 0 violations), xcodebuild -scheme MeetingTranscriber -destination platform=macOS SWIFT_SUPPRESS_WARNINGS=NO clean build-for-testing (rc=0) + swiftlint analyze --strict (rc=0, 0 violations in 806 files, at 98707b85), fix pass 1: cd app/MeetingTranscriber && swift build --build-tests (rc=0), fix pass 1: cd app/MeetingTranscriber && swift build -Xswiftc -DAPPSTORE (rc=0), fix pass 1: cd app/MeetingTranscriber && CFFIXED_USER_HOME=<fresh scratch> swift test --parallel --filter 'ProtocolGenerator|PipelineQueue|NotificationManager|OutputSettings|LocalModel|SpeakerNaming|WatchingController|WatchLoop|ProtocolRegenerat' (rc=1, 949 tests, 5 failed, all WatchLoopE2ETests: WhisperKit model download into the fresh scratch home; tree = d74072e4 before two lint fixes in the new test's assertions), fix pass 1: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/mt-flow/home-e2e swift test --filter 'WatchLoopE2ETests' (rc=0, 8 tests, 0 failures), fix pass 1: cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --filter 'LocalModelRecordingPreemptionTests' (rc=0, 8 tests, at d74072e4), fix pass 1 mutation: isRecordingActivity without detectedCapturesRunning turned testStopWatchingHoldsTheGateUntilTheMeetingsRecorderHasStopped red on its two gate assertions; source restored, fix pass 1: PATH=<pinned lint tools>:$PATH ./scripts/lint.sh (rc=0, 0 violations, 0 files need formatting), fix pass 1: xcodebuild clean build-for-testing SWIFT_SUPPRESS_WARNINGS=NO (rc=0, no warnings in touched files) + swiftlint analyze --strict (rc=0, 0 violations in 806 files, at d74072e4), conductor verify at e73813b8 (spec worktree): swift build rc=0; swift build -Xswiftc -DAPPSTORE rc=0; focused tests rc=0, 568 cases; App Store test variant --filter 'LocalModel|CommandProviderSettings' rc=0, 2 cases
- PRs: