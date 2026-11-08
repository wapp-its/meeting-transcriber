---
title: "File-name ownership must fold case to refuse, but match exactly to claim"
date: "2026-11-08"
track: bug
category: data
module: app/MeetingTranscriber/Sources/AdditionalReport.swift
tags: [case-insensitive, file-names, ownership, deletion]
problem_type: data
symptoms: A report could replace another meeting's notes whose name differed only in case
root_cause: Case-sensitive name comparisons on a case-insensitive volume; folding everywhere then over-claimed on case-sensitive volumes
resolution_type: fix
related_to: [bug/data/a-confirmation-skipped-on-zero-treated-2026-11-07, bug/data/a-deletions-recovery-mark-went-before-2026-11-06, bug/data/a-permanent-deletion-trusted-signals-2026-11-07]
---

## Problem
The additional-report ownership rule (`MeetingReportFolder`) compared file names case-sensitively. The default macOS volume is case-insensitive, so with another meeting's `Budget (q3).txt` and `Budget (q3).md`, the template "Q3" saw a free slot for `Budget (Q3).md`, and writing it replaced the other meeting's notes.

## What Didn't Work
Folding case in every comparison. That also widened what a meeting lists as its own reports: on a case-sensitive volume `Budget` and `budget` are two meetings, and Move Meeting to Trash on `Budget` would have taken `budget (Short).md`.

## Solution
Fold case only where it refuses or keeps a file: a `.txt` of the file's own name in any case makes it a meeting, a longer meeting claims a name in any case, and a case variant of the chosen report's name is the slot it replaces. List, move and delete reports only under the meeting's exact name (`AdditionalReport.swift`, `MeetingReportFolder.reports` and `owner(ofFileName:)`). The AI-title rename takes a report only to a `.free` slot (`ArtifactRenamePlan.availableStem`).

## Prevention
For any rule that decides from file names which files to write, move or delete, ask both questions: what does a case-insensitive volume reach under this name, and what does a case-sensitive volume keep apart? Fold case on the refusing side and compare exactly on the side that claims files for a destructive action. Pin both with pure tests on name sets (`AdditionalReportTests`, the case-variant tests).
