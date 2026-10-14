---
satisfies: [R3, R4, R7, R10, R12]
---
# gh-138-local-model-for-protocols-in-the.3 App side: local generator, helper runner, gate and memory guard

## Description
The app-side half of the process boundary: a `ProtocolGenerating` implementation that runs the helper through a cancellation-aware runner with progress-driven deadlines, an app-wide gate that admits one helper at a time with a memory admission check and a watchdog, the new provider case wired into the generator factory, and the model-folder setting it reads. No UI and no pipeline outcome mapping yet (tasks 5 and 6).

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/LocalModel/LocalModelProtocolGenerator.swift`, `LocalModelHelperRunner.swift`, `LocalModelGate.swift`, `LocalModelMemoryGuard.swift`, `LocalModelOutcome.swift` (all new), `app/MeetingTranscriber/Sources/AppSettings.swift`, `app/MeetingTranscriber/Sources/AppSettings+LocalModel.swift` (new), `app/MeetingTranscriber/Sources/PipelineController.swift`, tests under `app/MeetingTranscriber/Tests/LocalModel*Tests.swift`
**Touches:** [app/MeetingTranscriber/Sources/LocalModel/**, app/MeetingTranscriber/Sources/AppSettings.swift, app/MeetingTranscriber/Sources/AppSettings+LocalModel.swift, app/MeetingTranscriber/Sources/PipelineController.swift, app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift, app/MeetingTranscriber/Tests/LocalModelGeneratorTests.swift, app/MeetingTranscriber/Tests/LocalModelGateTests.swift, app/MeetingTranscriber/Tests/LocalModelMemoryGuardTests.swift]

### Approach
- Provider: add `.localModel` inside the `#if !APPSTORE` block of `ProtocolProvider` and its `label` (`AppSettings.swift:98-118`), label "Local model (on this Mac)"; handle it in `PipelineController.makeProtocolGenerator()` (`PipelineController.swift:334-367`) and in every other exhaustive switch over the provider in the same change, including `OutputSettingsView.providerConfigView` (no `default` case there), where this task adds only a placeholder case (an empty view) that task 6 replaces. Every new file is `#if !APPSTORE`.
- Setting: model folder as security-scoped bookmark plus display path, following `AppSettings+WhisperKitModel.swift:60-94` and `VocabularyFileAccess.resolve(path:bookmark:)` / `withAccess`. The helper receives the plain resolved path.
- `LocalModelOutcome`: a typed error the generator throws for every non-written outcome (incomplete with its text, deferred for a recording, low memory with readings, no model, prompt too long, deadline, failure), mirroring the helper's exit codes from task 1 in one place. `generate` returns text only for the written case.
- `LocalModelHelperRunner`: spawn the helper with an argument vector (no shell) and the request on stdin, read progress lines from stderr, reset the no-progress deadline on each, enforce the total deadline, and terminate (SIGTERM, then SIGKILL after a grace) on Swift task cancellation via `withTaskCancellationHandler`; `CLIProcessRunner` has no cancellation hook today (`CLIProcessRunner.swift:157`), so either add one there or keep a dedicated runner; do not change the CLI providers' behaviour.
- `LocalModelGate` (`@MainActor`, one shared instance owned by `PipelineController`): admits one helper at a time from the memory check until the helper's exit is confirmed; queued callers wait; records the owning job identity, read from a `@TaskLocal` job id that callers set (task 4 sets it at the call sites); `cancel(jobID:)` terminates the helper only if that job owns it.
- `LocalModelMemoryGuard` behind a probe protocol for tests: pressure level from `sysctl kern.memorystatus_vm_pressure_level`; available memory = `(UInt64(free_count) + UInt64(inactive_count)) * pageSize` from `host_statistics64` (`vm_statistics64`); `free_count` there already includes speculative pages, so never add `speculative_count` (the `vm_stat` tool prints them separately, which is misleading). Do not use `kern.memorystatus_level` (the `memory_pressure` "free percentage"): it also counts active pages, so other apps' working sets would satisfy the check. Do not add `purgeable_count` on top (it overlaps the inactive queue). Thresholds per the spec's A9; the watchdog polls while the helper runs and terminates it with the readings attached to the outcome. Under ordinary desktop load the two figures can differ by about a factor of two (78 % "free" against about 40 % free + inactive in one measurement).
- App log lines per R12 through the existing `Logger` subsystem, content-free.
- Before the memory check: the helper binary must exist in the bundle and be executable, else a failure outcome with its own log reason (not "no model").
- The app holds the model folder's security-scoped access from before the helper starts until its exit is confirmed.
- Deadlines count only time the Mac is awake (`SuspendingClock`); hold a `ProcessInfo.beginActivity` assertion while a helper runs so App Nap does not stall it.
- A helper ended by a signal is a failure; a model folder that is unreachable after the helper's exit reports as no model.
- Settings edits never terminate a running helper; a run uses the provider and folder captured at its start.
- The private run directory and its prompt files are owner-only, removed when the helper exits, and leftovers are removed at launch (they carry transcript text).
- The gate is released on every path (success, throw, cancellation, a helper that ignores SIGTERM). Its wait is cancellable, and a per-job cancelled set (speaker-naming tasks have no handles) keeps a job cancelled while waiting from ever starting a helper.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/CommandProtocolGenerator.swift:16-160` — the subprocess generator pattern and owner-only run directory
- `app/MeetingTranscriber/Sources/CLIProcessRunner.swift:149-260,378-385` — runner, timer and kill escalation
- `app/MeetingTranscriber/Sources/PipelineController.swift:325-367` — the generator factory and its direct unit test note
- `app/MeetingTranscriber/Sources/AppSettings+WhisperKitModel.swift:55-95` — bookmark pattern

**Optional:**
- `app/MeetingTranscriber/Tests/CLIProcessRunnerTests.swift` — fake `#!/bin/sh` programs in a scratch dir
- `app/MeetingTranscriber/Tests/TestHelpers.swift:367` — `MockProtocolGen`

### Key context
- Flow-next memory: the gate, the guard and the probes must be ready synchronously at init; nothing in `processNext` or `resumeProtocolOnly` may `await` them before the job's state transition (restored jobs race otherwise).
- Test with fake helper shell scripts that play each exit code and progress pattern; no test here starts the real helper.
## Acceptance
- [ ] Fake-helper tests: each exit code maps to its `LocalModelOutcome`; a helper that stops reporting progress is ended by the no-progress deadline; the total deadline ends a helper that keeps reporting; cancelling the calling task terminates the helper within the grace period.
- [ ] Gate tests: two concurrent `generate` calls never overlap (the second starts only after the first helper exited); `cancel(jobID:)` ends only the owning job's helper.
- [ ] A probe-conversion test from raw `vm_statistics64` counts: high active and little free/inactive memory is refused even though the total looks large. A conversion test with nonzero speculative pages shows they are not counted twice at the admission and termination boundaries. Guard tests with injected readings exactly at and just past the admission and termination boundaries: no start below the admission thresholds (low-memory outcome, helper never spawned); the watchdog terminates a running fake helper on warning pressure or below the floor, with the readings in the outcome.
- [ ] The App Store variant builds unchanged (`swift build -Xswiftc -DAPPSTORE`) and offers no new provider case.
- [ ] No log line contains transcript or protocol text.
- [ ] A fake helper that ignores SIGTERM is killed after the grace period and the gate is free again; a job cancelled while waiting at the gate never spawns a helper.
- [ ] A missing helper binary, a signal death and a folder that vanished during the run each map to the outcome the spec's edge cases name.
- [ ] The run directory is gone after every outcome, and a leftover one is removed at launch.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
