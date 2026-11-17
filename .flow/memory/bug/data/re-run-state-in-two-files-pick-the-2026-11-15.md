---
title: "Re-run state in two files: pick the newer copy per path, not one side"
date: "2026-11-15"
track: bug
category: data
module: app/MeetingTranscriber/Sources/PipelineQueue+RerunRecovery.swift
tags: [rerun, persistence, crash-recovery, journal]
problem_type: data
symptoms: Retry entries lost or later re-runs refused after a crash or a failed record write
root_cause: "Two copies of a re-run's state were reconciled by always preferring one side, though which side is newer depends on the path"
resolution_type: fix
related_to: [bug/data/a-deletions-recovery-mark-went-before-2026-11-06, bug/data/a-permanent-deletion-trusted-signals-2026-11-07]
---

## Problem
A re-run keeps its job in its own file beside `pipeline_queue.json`, and the meeting's record is its journal. The review found that copies of the same state in separate files went stale against each other: the finished entry a re-run took over was in only one of two independently written files during the hand-over, a re-run's marker was taken from the record even where the live job knew newer files, and a job read back at launch was trusted over the record although it is written less often.

## What Didn't Work
Letting one copy of the marker always win. The live job is newer than the record (it is updated first, and a record write can fail); a job read back from the file is older (the file is written at state changes, the record at each file write), except when it was saved because its end could not be recorded. Each fix that picked one side broke the other case in the next review round.

## Solution
- `snapshotJobs` (`PipelineQueue+RerunRecovery.swift`): `pipeline_queue.json` keeps the taken-over entry for as long as the re-run holds it, so one saved copy exists whichever file lands first.
- `merged(_:into:ownIsNewer:)`: the union of both file lists, with the newer copy's identity where both list a path; the live end passes true, the launch passes `endDecided`.
- An end that could not be recorded is saved in `.error`, which the launch reads as an end to finish; a launch's own failed end keeps the job as saved, since the next launch derives the same row again.

## Prevention
For every piece of state kept in two places, write down which copy is newer on each path (live, saved, recovered) before choosing a winner, and test a crash between the two writes in both directions.
