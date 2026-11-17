---
title: Stale async answer overwrote a summary another running build had changed
date: "2026-11-17"
track: bug
category: data
module: app/MeetingTranscriber/Sources/MeetingSummarizer.swift
tags: [shared-file, second-build, stale-answer, lock]
problem_type: data
symptoms: A late summary call answer replaced newer notes' summary or revived a removed one
root_cause: "Invalidation token lived only in process memory, not in the file both builds write"
resolution_type: fix
---

## Problem
The meeting-summary call stored its answer when the in-process dictionary of each meeting's latest notes save still named the call's save. A second running build shares the summary file (Homebrew and Dev builds side by side), so a newer notes save or a Move to Trash in that build was invisible: the late answer overwrote the newer summary or brought a removed one back. Clearing the summary in the Edit Summary sheet had the same hole inside one build, because it changed the file but not the in-process token.

## What Didn't Work
An in-process "latest save" map (`latestSave[jobID]`) plus task cancellation. It covers newer saves in the same process only; the lock-guarded read-modify-write of the file kept other meetings intact but did not stop a stale answer for the same meeting.

## Solution
The summary file records each meeting's latest notes save (`MeetingSummaryStore.beginNotesSave`). An answer is stored through `commit(save, jobID:)`, which re-reads the file under the lock and applies the change only while the file still holds that save; clearing or removing a meeting drops its recorded save, and the launch prune drops saves of gone meetings. The in-process map stays for cancelling calls early.

## Prevention
Any background result written into a file that another running build also writes needs its invalidation token in that file, checked under the same lock as the write. Test it with two stores on one path and a held call (`MeetingSummarizerTests.testAnotherBuildsSaveOrRemovalAndAClearedSummaryDropTheAnswer`).
