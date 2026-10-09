---
title: Recovery left a recording unsettled but the orphan scan still queued its mix
date: "2026-10-09"
track: bug
category: data
module: app/MeetingTranscriber/Sources/RecoveredCut.swift
tags: [recovery, orphan-scan, recovered-cut, staging]
problem_type: data
symptoms: a recording whose hidden original track could not be restored was queued uncut and without that track
root_cause: the orphan scan queues every untracked mix on disk; the recovered cut skipped its own work but did not tell the scan
resolution_type: fix
---

## Problem

The launch recovery of the staging folder runs its own steps (collect stored
meeting-end cuts, repair headers, re-mix crashed recordings, apply the cuts)
and then the orphan scan, which queues every untracked `_mix.wav` it finds.
When the recovered cut could not rename an original track back from its hidden
`.uncut` name, `RecoveredCut` kept the stored cut for a later pass, but the mix
was still on its path, so the orphan scan queued the recording uncut and
without the hidden track, which nothing processed afterwards.

## What Didn't Work

Hiding the mix as well (renaming it to its own hidden name, which every pass
restores first). It depends on one more rename that the same file system
failure can refuse, and on no original already sitting under the mix's hidden
name; the reviewer rejected it as a barrier.

## Solution

`RecoveredCut.apply` returns the stems it left unsettled, and
`PipelineController.recoverOrphans(into:holdingBack:recordingsDir:)`
(`PipelineController+ProductionEnvironment.swift`) holds each one's mix in the
queue's `InFlightRunRegistry` for as long as the orphan scan runs. The scan
already skips audio a run holds (`runningPaths`), so the barrier needs no file
operation, and the hold ends with the scan, so the next pass restores the track
first and then queues the recording.

## Prevention

Any recovery step that decides a staged recording must not be processed yet has
to tell the orphan scan, not only skip its own work: the scan queues whatever
mix is on disk. Test the hold with a private `InFlightRunRegistry` and a temp
recordings folder (`StagedRecoveryFolderTests`), since the production pass scans
the real folder.
