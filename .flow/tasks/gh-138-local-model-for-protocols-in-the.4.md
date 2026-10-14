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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
