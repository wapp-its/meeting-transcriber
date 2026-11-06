---
title: A deletion's recovery mark went before the other writes were on disk
date: "2026-11-06"
track: bug
category: data
module: app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift
tags: [deletion, crash-recovery, persistence, snapshot, meeting-file-record]
problem_type: data
symptoms: After a crash or failed write a moved meeting came back with its files gone and no way to remove it; a folder at a sidecar path was deleted for good
root_cause: "The pending mark was cleared while an earlier write was only scheduled or had failed silently, and the queue's cleanup still removed sidecars by name"
resolution_type: fix
related_to: [bug/data/a-meetings-file-record-assumed-what-a-2026-11-06]
---

## Problem
Move Meeting to Trash ended in three writes: the queue's snapshot, the finished-job history and the meeting's record. The record holds the pending mark, which is the only thing a launch repairs a stopped deletion from. It was removed first in effect: the snapshot is written off the main actor, and `TerminalJobStore` logs a failed write and goes on. A crash or a failed write then left the old snapshot or history listing a meeting with no mark, so it came back with its files gone and every action refused it. The same pattern hid in the mover: a failed write of a file's own state was ignored, and a later write cleared the mark while the file still read as being deleted.

Separately, the final `removeJob` deleted the naming sidecars by file name with `FileManager.removeItem`, behind the mover's checks. A folder sitting at a path the record already marked as gone was removed for good, content included.

## What Didn't Work
Ordering the calls so the record came last looked crash-safe, and a comment said so. Order alone proves nothing when an earlier call in the sequence only schedules its write, or swallows its failure.

## Solution
- `TerminalJobStore.remove` reports whether its write landed.
- `PipelineController.removeMovedMeeting` removes the record only when no snapshot write is owed: at once when `queue.isSnapshotWorkerActive` is false, otherwise after `queue.awaitSnapshotFlush()`. Still active after a flush means the write failed, so the mark stays and the next launch finishes the removal.
- `MeetingFileStore.finishDeletion` sets each file's state from its outcome in the same write that clears the mark.
- `PipelineQueue.removeJob(id:keepingFiles:)` forgets the job's naming data and leaves the disk alone.

## Prevention
Before removing the mark that recovery depends on, check that every step before it reports that its write is on disk. A store that logs and continues, or a save that only schedules a write, does not count. Test each step with its write failing, then run the next launch's reconcile on what the failed write left. A folder at a staging path fails a write without a mock. `MeetingFileStore.save` removes the staging path after a failure, so there the folder fails one write only. When a checked removal hands over to older cleanup code, read what that code deletes: a caller that has checked its files must not fall through to a removal by name.
