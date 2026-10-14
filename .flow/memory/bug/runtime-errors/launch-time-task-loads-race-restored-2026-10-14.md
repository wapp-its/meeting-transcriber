---
title: Launch-time Task loads race restored stages; processNext must not suspend early
date: "2026-10-14"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift
tags: [pipeline-queue, concurrency, launch, stage-timing]
problem_type: runtime-error
symptoms: A stage resumed at launch never got its expected finish; an await in processNext made 19 queue tests fail
root_cause: History read in a background Task finished after the restored stage started; any suspension before the job leaves .waiting lets a second processNext take it
resolution_type: fix
related_to: [bug/runtime-errors/async-probe-result-adopted-after-its-2026-10-09]
---

## Problem
A stage's expected finish (the menu's "ready about" time) is filled in only when the stage starts or when its audio length is measured. Later history reloads never fill it in, which is what keeps the menu still. The timing history was read in a background `Task` from `PipelineQueue.init`. A job that the snapshot restore resumes mid-protocol enters `.generatingProtocol` right at launch, before that read finished, so its finish stayed empty for the whole stage. The codex impl-review reproduced it through `loadSnapshot()`.

## What Didn't Work
Awaiting the background read at the top of `processNext()` made 19 `PipelineQueueTests` fail. Many of those tests `enqueue` a job (which schedules a `processNext` Task through `triggerProcessing`) and then call `await queue.processNext()` themselves. Before this change, `processNext` claimed the job and moved it out of `.waiting` without suspending. With an `await` in front of that, the scheduled run took the job instead, and the direct call returned early, so its assertions read a half-run job. An `await` placed after the claim is worse: the second run hits `refusedSameJob` in `claimRunOrGiveUpDuplicate`, which removes the job from the queue.

## Solution
The queue now reads the history synchronously in `init`, the same way it reads its snapshot and its job history. `StageTimingLog.loadRecentNow(within:)` is a `nonisolated` read that shares one parsing function with the actor's own `loadRecent` (`Sources/StageTimingStats.swift`). The read is called at the end of the full `PipelineQueue.init`. `processNext` keeps its rule of never suspending before the job leaves `.waiting`. The regression test is `PipelineQueueStageClockTests.testAStageResumedAtLaunchReadsTheHistory`: it is red when the read at creation is disabled.

## Prevention
- Never put an `await` in `PipelineQueue.processNext` before the job leaves `.waiting` (via `updateJobState(.transcribing)`, or inside `resumeProtocolOnly` before `.generatingProtocol`).
- State that a stage needs when it starts must exist by the time the queue does. Read it in `init`, not in a launch `Task`.
- Test launch-time behaviour through `loadSnapshot()` plus `awaitProcessing()`, capturing state in `onJobStateChange`.
