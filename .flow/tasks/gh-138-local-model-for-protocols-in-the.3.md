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
The app can now write a protocol with a local MLX model through the bundled helper. A new provider "Local model (on this Mac)" runs the helper through one app-wide gate that admits one helper at a time, checks memory before the start, watches it during the run, enforces the progress and total deadlines, and maps every helper end to a typed `LocalModelOutcome`.

baseline: green via handoff (verified at 6dadc040 by task .1; only .flow/ paths moved since), lint baseline rc=0
stage: impl-review - skipped(policy: parallel-wave - conductor owns the gate)
Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

### Acceptance criteria and their tests

- Exit codes to outcomes, no-progress deadline, total deadline, task cancellation within the grace: `LocalModelGeneratorTests.testEachExitStatusMapsToItsOutcomeAndLeavesNoRunDirectory`, `testDeadlinesEndAHelperThatStopsReportingOrNeverFinishes`, `testCancellingTheCallingTaskEndsTheHelperWithinTheGrace`.
- Gate never overlaps, `cancel(jobID:)` ends only the owner's helper: `LocalModelGateTests.testConcurrentGenerationsNeverOverlap` (goes red when the gate's owner check is removed, checked by mutation), `testCancelEndsOnlyTheOwningJobsHelper`.
- Probe conversion, speculative pages not counted twice, boundaries: `LocalModelMemoryGuardTests` (all seven tests). Low memory at the start never spawns, watchdog ends a running helper with the readings in the outcome: `LocalModelGateTests.testAdmissionNeedsNormalPressureAndTheWeightsPlusHeadroom`, `testWatchdogEndsARunningHelperOnWarningPressureOrBelowTheFloor`.
- App Store variant: `swift build -Xswiftc -DAPPSTORE` rc=0; `LocalModelGeneratorTests.testAppStoreVariantOffersNoLocalModelProvider` pins `allCases` under APPSTORE (not run locally, CI runs the App Store tests).
- No log line carries transcript or protocol text: `testNoLogLineCarriesTranscriptOrProtocolText`.
- SIGTERM-ignoring helper killed after the grace and gate free, job cancelled while waiting never spawns: `LocalModelGateTests.testHelperIgnoringSigtermIsKilledAfterTheGraceAndTheGateIsFreeAgain`, `testJobCancelledWhileWaitingOrBeforeArrivingNeverStartsAHelper`.
- Missing helper, signal death, vanished folder: `testMissingOrNonExecutableHelperIsAFailureOfItsOwn`, the exit table's `kill -KILL` row, `testFolderThatVanishedDuringTheRunIsNoModel`.
- Run directory gone after every outcome, leftovers removed at launch: the exit table and deadline tests check `runDirectoryNames == []`; `testRunDirectoriesOfEndedProcessesAreRemovedAtLaunch`.

### Hooks for later tasks

- Task 4 sets `LocalModelGate.$jobID.withValue(job.id) { ... }` around the provider call, calls `gate.cancel(jobID:)` on a job cancel, `gate.setRecordingActive(_:)` at recording start and full stop, and `gate.terminateForQuit()` at quit. The gate is `PipelineController.localModelGate`. A recording ends the running helper with `LocalModelOutcome.deferredForRecording` and admits nothing until it stops.
- Task 6 uses `AppSettings.setLocalModelFolder(_:)`, `AppSettings.localModelFolder` and `LocalModelHelperLocator.locate()`, and replaces the `EmptyView()` case in `OutputSettingsView.providerConfigView`.
- Feature route changed: Settings, Output, the protocol provider picker now lists "Local model (on this Mac)" (its config view is empty until task 6).

### Decisions

1. Rule 6. Grace before SIGKILL 3 s (`LocalModelLimits.killGrace`), at quit 1 s (`quitGrace`, the quit blocks the main thread), deadline and watchdog poll every 1 s (`pollInterval`), stderr drain after exit 2 s (`drainAfterExit`). All limits live in `LocalModelLimits`.
2. Rule 6. The gate's line is FIFO by arrival. A job whose helper a recording ended keeps its original place, so jobs deferred by one recording resume in their order. Pinned by `testRecordingEndsTheHelperAndDeferredJobsResumeInTheirOrder`.
3. Rule 6. Recording preemption, the deferred order and the quit stop live in the gate (`setRecordingActive`, `terminateForQuit`), because task 4's Touches exclude `LocalModel/**`.
4. Rule 6. The helper locator searches `Contents/Helpers` first, then `Contents/MacOS`; task .2's notes measured that the helper fails beside the app executable. Pinned by `testHelperIsFoundInHelpersBeforeMacOS`.
5. Rule 3, shape named by the Approach (WhisperKit custom-folder pattern). Settings keys `localModelFolderPath` and `localModelFolderBookmark`; provider raw value `localModel`. A stale bookmark is not refreshed, as for the WhisperKit folder.
6. Rule 6. The thresholds use GiB (`6 << 30`, `4 << 30`). An unreadable figure fails closed: unknown pressure is not normal, unreadable available memory reads as 0.
7. Rule 6. Outcome precedence in `LocalModelOutcome.resolve`: a cancellation wins over everything, the written text included; exit 0 and 10 (text) and 11 and 12 (verdicts before loading) win over any other stop the app asked for; that stop explains every other end; then an unreachable folder reads as no model; else a failure with the status or signal. Exit 13 or 1 that the app did not ask for is `failure(.exitStatus)`. Pinned by `testWhichEndWinsWhenTheAppAskedForAStop`.
8. Rule 6. The request goes to the helper as an owner-only file (0600) opened as its stdin, inside a 0700 run directory that is also its working directory; the protocol is written to `protocol.md` there.
9. Rule 4 (UX copy). `ProtocolDestination` for the local model is `.local(host: "this Mac")`, so the options window reads "Background info stays on this Mac: it goes with the transcript to the local model at this Mac." Switch point `ProtocolDestination.resolve` in `MeetingProtocolOptions.swift`; pinning test `testLocalModelSendsTheTranscriptNowhereButThisMac`.
10. Rule 6. While a helper runs the app holds `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` against App Nap; idle sleep stays allowed and the deadlines use `SuspendingClock`.
11. Rule 6. The cancelled-job set lives as long as the gate (the app session). A cancelled job id is refused for every later local generation in that session, so a regeneration of a cancelled job needs a fresh id or an explicit un-cancel in task 4.
12. Rule 1 (helper README). Only `progress` lines reset the no-progress deadline; `lifecycle` lines do not. Stderr lines longer than 4096 bytes, or of any shape outside the contract, are dropped unread and never logged.
13. Rule 6. Run directories carry the creating pid in their name; the launch sweep removes only those whose process no longer runs, because the dev build, the release build and test processes share the per-user temporary directory.
14. Rule 1 (project facts). The weight size is the sum of the top-level `*.safetensors` regular files after following symlinks (Hugging Face cache layout), computed by the app before the start.

### Touches extended

- `app/MeetingTranscriber/Sources/MeetingProtocolOptions.swift`: the exhaustive switch in `ProtocolDestination.resolve` failed to compile without the new case; one case added.
- `app/MeetingTranscriber/Tests/CommandProviderSettingsTests.swift`: `testProviderOrderAndLabels` pins `ProtocolProvider.allCases`; updated to include `.localModel`, which this task adds by declared intent.

### Follow-ups

- `app/MeetingTranscriber/Sources/RPCStateSnapshot.swift:400`: its doc comment lists the provider raw values without `localModel` (outside this task's Touches).
- The App Store test variant (`swift test -Xswiftc -DAPPSTORE`) was not run locally; only the App Store build was.

### Fix pass 1

Two review findings fixed, one commit each (`ef3e789b`, `0ae97746`); range now `64689dfd..0ae97746`.

- **Finding 1 (P1), indexed shards.** `LocalModelMemoryGuard.weightBytes(in:)` now counts the files the helper's folder check and the pinned loader pick: with `model.safetensors.index.json`, the distinct files its `weight_map` names, relative to the folder (subfolders included, symlinks followed); without an index, the top-level `*.safetensors` files. It returns nil for an index that cannot be read or names a file that is not a regular file. The generator refuses a nil size before the gate, so no helper starts. Tests: `LocalModelMemoryGuardTests.testWeightBytesCountTheFilesTheHelperLoads` (table: top level, index into a subfolder with a symlinked and a duplicate shard and an unnamed top-level file, no weights, missing shard, index that is not JSON, dangling link), `LocalModelGateTests.testAdmissionCountsTheShardsAnIndexNamesInASubfolder` (8000 bytes of nested shards: refused one byte under weights plus headroom, written at it), `testIndexNamingAMissingShardIsNoModelAndStartsNoHelper`. With the index lookup disabled by mutation, the two gate tests failed (5 assertions).
- **Finding 2 (P2), deferred job's place.** The gate now holds a deferred job's place from the deferral on (`heldPlaces`, replacing `deferredOrder`): nobody behind it is admitted, on arrival or in `admitNext`, until it comes back. A job that does not come back frees the place after `LocalModelLimits.deferredHold` (10 s), logged as `local_model_place_freed`; `cancel(jobID:)` frees it at once and re-runs admission. Tests: `testDeferredJobKeepsItsPlaceWhenTheRecordingEndsBeforeItsHelperExited` (helper takes about 0.35 s to exit after SIGTERM, recording ends inside that, later job already waiting; asserts `first,second`; with the hold removed by mutation it printed `second,first`), `testPlaceOfADeferredJobThatDoesNotComeBackIsFreedAfterTheHold`. `testRecordingEndsTheHelperAndDeferredJobsResumeInTheirOrder` still passes.

### Decisions (fix pass)

15. Rule 4 (outcome the user sees). An unknown weight size is refused as `noModel` (log `local_model_refused ... reason=no_model weights=unknown`), not `lowMemory`. Both fail closed and start no helper. `noModel` is the verdict the helper's own folder check reaches for the same index (exit 11), and a low-memory notice would send the user to close apps instead of fixing the folder. Switch point: the `weightBytes` guard in `LocalModelProtocolGenerator.generate`. Pinning test: `testIndexNamingAMissingShardIsNoModelAndStartsNoHelper`.
16. Rule 6. A folder with no index and no top-level weight files counts as 0 bytes, not unknown. The helper then rejects the folder with exit 11 (`noModel`) before loading anything, so this cannot under-count memory.
17. Rule 6. The hold on a deferred job's place lasts 10 s (`LocalModelLimits.deferredHold`). The caller retries at once, in milliseconds. The hold only bounds how long the line waits for a caller that never comes back (a regeneration a recording ended), which would otherwise stall every later job. Pinned by `testPlaceOfADeferredJobThatDoesNotComeBackIsFreedAfterTheHold`. Decision 2 (FIFO with the deferred job keeping its place) stands. Decision 14 is superseded by the index rule above.

### Re-run results at `0ae97746`

- `swift test --parallel --filter 'LocalModel|CommandProviderSettings|ProtocolGenerator|PipelineQueue|NotificationManager|OutputSettings'` under a scratch `CFFIXED_USER_HOME`: rc=0, 535 tests (34 of them `LocalModel*`).
- `swift build -Xswiftc -DAPPSTORE`: rc=0.
- `./scripts/lint.sh` with the pinned tools: rc=0, 0 violations in 881 files, none need formatting.
- Clean `xcodebuild ... build-for-testing` (rc=0), then `swiftlint analyze --strict`: rc=0, 0 violations in 802 files.


stage: impl-review - ran [20:33:27Z..21:04:15Z] (model: codex gpt-6-astra xhigh; round 1 three draws, all NEEDS_WORK: one P1 shared by all three, indexed weight shards not counted by the memory admission, and one P2 in two draws, a deferred job losing its place; the validator pass was not run, both findings were taken as real and fixed; round 2 one reviewer, resumed session, both fixed) - SHIP
stage: wave-join - ran (the lane's five commits replayed onto the spec branch by cherry-pick because task .2 had landed first; lane 0e2baf08, c0154855, bc935267, ef3e789b, 0ae97746 became cd95b0c4, e0cd81cd, 509ad32c, 11e51383, 6e59cf6f; the evidence commit list names the lane SHAs, the range below names the spec-branch ones)
stage: conductor-verify - ran at the fix head (lane 0ae97746, same app content as spec 6e59cf6f): swift build rc=0, swift build -Xswiftc -DAPPSTORE rc=0, focused tests rc=0 (544 cases, filter ProtocolGenerator|PipelineQueue|NotificationManager|OutputSettings|LocalModel|CommandProviderSettings|ProtocolDestination|MeetingProtocolOptions), App Store test variant rc=0 (2 cases, filter LocalModel|CommandProviderSettings, which the worker had not run)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: cd95b0c4f3ea2252d483ecb6c1bb79fbe2339bed, e0cd81cdeca799c814f7f7c4f4a80ce3a42ca742, 509ad32cabf0ae271a0377ccfd06da35061a3c48, 11e513839aa9027b8944ae909c9d42bea81e866c, 6e59cf6f6b26500f826a3d6b452e341e4eda4ff1
- Tests: cd app/MeetingTranscriber && swift build (rc=0, at c0154855), cd app/MeetingTranscriber && swift build -Xswiftc -DAPPSTORE (rc=0, at c0154855; bc935267 touches only #if !APPSTORE files), cd app/MeetingTranscriber && CFFIXED_USER_HOME="$(mktemp -d)" swift test --parallel --filter 'ProtocolGenerator|PipelineQueue|NotificationManager|OutputSettings|LocalModel|CommandProviderSettings|PipelineController|ProtocolDestination|AppSettings' (rc=0, 666 tests, at c0154855), cd app/MeetingTranscriber && CFFIXED_USER_HOME="$(mktemp -d)" swift test --parallel --filter 'LocalModel' (rc=0, 30 tests, at bc935267), PATH=<pinned lint tools>:$PATH ./scripts/lint.sh (rc=0, 0 violations in 881 files, 0/881 need formatting, at bc935267), xcodebuild -scheme MeetingTranscriber -destination platform=macOS SWIFT_SUPPRESS_WARNINGS=NO clean build-for-testing + swiftlint analyze --strict (rc=0, 0 violations in 802 files, at c0154855), fix pass 1: cd app/MeetingTranscriber && CFFIXED_USER_HOME="$(mktemp -d)" swift test --parallel --filter 'LocalModel|CommandProviderSettings|ProtocolGenerator|PipelineQueue|NotificationManager|OutputSettings' (rc=0, 535 tests, at 0ae97746), fix pass 1: cd app/MeetingTranscriber && swift build -Xswiftc -DAPPSTORE (rc=0, at 0ae97746), fix pass 1: PATH=<pinned lint tools>:$PATH ./scripts/lint.sh (rc=0, 0 violations in 881 files, 0/881 need formatting, at 0ae97746), fix pass 1: xcodebuild -scheme MeetingTranscriber -destination platform=macOS SWIFT_SUPPRESS_WARNINGS=NO clean build-for-testing (rc=0) + swiftlint analyze --strict (rc=0, 0 violations in 802 files, at 0ae97746), conductor verify at lane 0ae97746 (= spec 6e59cf6f for app/): swift build rc=0; swift build -Xswiftc -DAPPSTORE rc=0; focused tests rc=0, 544 cases; App Store test variant --filter 'LocalModel|CommandProviderSettings' rc=0, 2 cases
- PRs: