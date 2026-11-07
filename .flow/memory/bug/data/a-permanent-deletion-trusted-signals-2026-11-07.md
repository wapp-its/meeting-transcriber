---
title: A permanent deletion trusted signals that say less than they seem to
date: "2026-11-07"
track: bug
category: data
module: RecordingRetentionController
tags: [deletion, retention, cross-process, snapshot, crash-recovery]
problem_type: data
symptoms: "Audio deleted with a folder or dangling link at the notes path, with an unread snapshot, or behind another build's Keep"
root_cause: "Presence, an engine and a compare before the mark were each read as proof of more than they establish"
resolution_type: fix
related_to: [bug/data/a-deletions-recovery-mark-went-before-2026-11-06]
---

## Problem

A permanent deletion rested on signals that say less than they seem to. "Something is at the notes path" (`lstat`) is also true of an empty folder or a dangling link, so the audio went while no notes existed. "The queue has an engine" was read as "the queue read its snapshot", but a failed read leaves an engine and an empty list, so a stale finished record passed the check. A compare under the lock before the deletion's mark does not help against a write that was decided before the mark and lands after it: another build's Keep did exactly that, and every file still went. A pending mark written for audio that was already gone let a crash date a deletion the app never did.

## What Didn't Work

Re-reading the record and the queue right before the mark, then comparing under the lock, closes the window before the mark only. A presence probe built for "may this entry be marked gone" was reused as the proof that notes are saved, which is a different question.

## Solution

Ask each question with a probe made for it: `MeetingFilePresence.isReadableFile` for the notes gate (regular file, readable, through a link too). Record a failed read on the queue (`snapshotRestoreFailed`, handed on in `adoptJobs`) and answer unsettled and listed until the next launch. Make the competing write decide under the same lock (`MeetingFileStore.setKeep` refuses while a deletion is pending), and have the deletion ask the record under the lock before each file (`startRemoving` with `RecordingRetentionRule.recordAllowsDeletion`), for writes that take no notice of the mark. Begin no deletion when no file answers present. Request a check after a rebuild, as a restore can finish a job before the queue has its callbacks.

## Prevention

For an action with no way back, list what each guard actually proves and try the states that satisfy it falsely: a folder or a link at a file's path, a load that failed quietly, a write decided before the mark and landing after it, a crash right after each write. Test a mark that must never be written by looking at the record file at every write (the store saves first and tells observers afterwards), since the final state cannot show it. Keep a positive case beside each new refusal, so a guard cannot pass by refusing everything.
