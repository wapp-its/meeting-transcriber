---
title: A confirmation skipped on zero treated could-not-tell as nothing to delete
date: "2026-11-07"
track: bug
category: data
module: RecordingRetentionController
tags: [deletion, retention, confirmation, preview, fail-safe]
problem_type: data
symptoms: A shorter retention saved with no alert when the records or the snapshot did not read or a meeting finished during the read; the next check deleted audio
root_cause: "An empty preview skipped the alert, and failed reads and a pre-await selection also produced an empty preview"
resolution_type: fix
---

## Problem

A confirmation that is skipped when its count is zero treats "zero" as permission to go ahead. The retention preview answered zero in three cases where zero was not known: the record file did not read and the store's older records answered; the queue's snapshot did not read and a protective synthetic `.waiting` read as a job known to be waiting; a meeting finished during the asynchronous disk read and the selection from before the wait answered. Each saved a shorter retention with no alert, and the next check deleted audio for good that no alert had named.

## What Didn't Work

Reusing the check's own lookups without looking at what their failure looks like. `store.reload()` discarded its result, and `liveMeetingState` answers `.waiting` on purpose, as that is the safe answer for a check about to delete. The same value is the unsafe answer for a preview about to skip asking.

## Solution

`MeetingFileStore.reload()` reports a failed read. `PipelineController.knowsLiveState` tells a known job from the protective answer, and `RetentionPreview.Selection.isComplete` goes false for a meeting the record would let go whose job cannot be known. `RecordingRetentionController.preview(for:)` returns an optional: nil on any of these, so the caller has to decide, and `RetentionChoice` then saves nothing and says so. It asks the rule again after each disk read until nothing unread is selected, so the answer comes from a selection made after the last suspension.

## Prevention

When a step is skipped on an empty result, separate "known empty" from "could not tell" in the type, and re-derive that result after every suspension. A fail-safe default is safe only for the decision it was made for: check each new reader of it. Test by making each input unreadable and by changing state while the await is held, then keep a positive case beside each refusal (a job the queue holds, a job a readable snapshot says is waiting), so a guard cannot pass by refusing everything.
