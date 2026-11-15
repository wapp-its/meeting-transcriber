---
title: An export hook rewrote run inputs captured at admission from the live job
date: "2026-11-15"
track: bug
category: data
module: app/MeetingTranscriber/Sources/PipelineQueue+Notion.swift
tags: [meeting-file-record, run-inputs, notion, regenerate]
problem_type: data
symptoms: A regenerated template on a held job replaced the template the meeting entered processing with
root_cause: "The hook copied every field from the live job, whose template changes after admission"
resolution_type: fix
related_to: [bug/data/a-deletions-recovery-mark-went-before-2026-11-06, bug/data/a-meetings-file-record-assumed-what-a-2026-11-06]
---

## Problem
A meeting's file record gained the run inputs a re-run needs (mic delay, pauses, mute spans, template, background, Notion page and database). The Notion hook that already updates the record (`noteNotionExport`) wrote all of them again from the live job on every export-state save. A job held after a failed export can have its notes regenerated from another template (`recordRegeneratedTemplate`), which saves the export state again, so the record took the regenerated template. A Regenerate Notes on a meeting that had left the queue does not touch the record, so the same action left two different records depending on whether the job was still held.

## What Didn't Work
Rewriting the whole value from the live job looked self-healing: it also gave the inputs back to a record an older build had rewritten without them. But the live job is not a frozen copy of what the meeting entered processing with: some of its fields keep changing after admission.

## Solution
The hook writes only the fields it owns, the page and its database, into the kept inputs, and takes all of them from the job only when the record has none (`PipelineQueue+Notion.swift`, `noteNotionExport`). A test regenerates the template of a held job and checks the record keeps the first one.

## Prevention
A hook that writes into a value captured at admission writes only the fields its event produced. Before rewriting a captured value from the live object, list every writer of each field after admission (here `recordRegeneratedTemplate` for `protocolTemplate`) and test one of them.
