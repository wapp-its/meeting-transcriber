---
title: A re-run's swap took a returned flush for a saved done state
date: "2026-11-16"
track: bug
category: data
module: app/MeetingTranscriber/Sources/PipelineQueue+RerunSwap.swift
tags: [rerun, crash-recovery, snapshot, persistence]
problem_type: data
symptoms: "A stop during a re-run's swap could leave the re-run file with the job before its done state, which the launch does not read as a swap"
root_cause: PipelineSnapshotStore.flush also returns after a write and its retry failed; the swap did not check that nothing was owed
resolution_type: fix
related_to: [bug/data/a-deletions-recovery-mark-went-before-2026-11-06, bug/data/a-permanent-deletion-trusted-signals-2026-11-07, bug/data/re-run-state-in-two-files-pick-the-2026-11-15]
---

## Problem
A re-run's swap renames the meeting's files, and after its commit point only the re-run job in this build's re-run file says what is left: whether the re-run made notes and whether an export is owed. The swap awaited `PipelineSnapshotStore.flush` and then started its renames. A flush also returns after a write and its one retry failed, so with the re-run file not writable the swap ran while the file still held the job before its done state. A stop during the swap then left a job the launch rows of the swap never read as a swap.

## What Didn't Work
Awaiting the flush before the first rename looked like a durability barrier. Recovering the swap from the record's marker whatever the saved job state was the other option, but the commit clears the marker, so after it the record no longer knows what the job owed.

## Solution
`PipelineQueue.rerunSucceeded` (`PipelineQueue+RerunSwap.swift`) starts the swap only when `PipelineSnapshotStore.existing(for: logDir, named: rerunFilename)` is nil after the flush: a store left after a flush is a write that failed again. Otherwise the re-run ends as a failed step before any rename (R6).

## Prevention
Treat a returned flush as "nothing more will be tried", never as "written": check that nothing is owed after it before an irreversible step that a crash recovery reads from that file. Test with the write failing: a folder at the file's staging name (`<name>.tmp`) fails every write of the snapshot store without a mock, and creating it from `onJobStateChange` at a chosen stage leaves an earlier state on disk.
