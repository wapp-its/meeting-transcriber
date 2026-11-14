---
title: Orphan scan's legacy ledger seeding hid crashed recordings on record-only instal
date: "2026-11-14"
track: bug
category: data
module: app/MeetingTranscriber/Sources/PipelineQueue+OrphanRecovery.swift
tags: [orphan-recovery, processed-ledger, record-only, production-path]
problem_type: data
symptoms: record-only recovery filed nothing on the real staging folder; temp-folder tests passed
root_cause: "one-time migration seeded every staged mix as processed when no ledger existed, gated on the production staging path"
resolution_type: fix
---

## Problem
Record-only recovery passed every test on temporary staging folders but filed nothing on the real staging folder. The orphan scan ran a one-time ledger migration only when its folder was `AppPaths.recordingsDir`: with no `processed_recordings.json` it marked every mix in staging as processed. A record-only install never finishes a job, so it never writes the ledger, and the first crashed recording was marked processed before the pass could file it, then skipped by every later pass. The review found it with an isolated-home probe on the production staging path.

## What Didn't Work
Tests on temporary staging folders: the migration branch is gated on the production folder, so no temp-dir test reaches it.

## Solution
Removed the migration from `scanForOrphanedRecordings` (`PipelineQueue+OrphanRecovery.swift`) and `ProcessedRecordingsLedger.migrate` with its tests. Finished jobs move their audio out of staging and record the mix in the ledger, so the migration only ever found unfinished recordings; the scan's 24-hour age limit covers very old ones.

## Prevention
When a test passes on a temporary folder, check whether the code branches on the production path (`== AppPaths.recordingsDir` or similar). Such a branch is invisible to the suite; reason about it, or have the reviewer run an isolated-home probe (CFFIXED_USER_HOME) rather than a committed test on the real folder.
