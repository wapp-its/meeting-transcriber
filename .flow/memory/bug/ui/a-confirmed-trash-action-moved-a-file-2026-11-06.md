---
title: A confirmed Trash action moved a file its dialog never named
date: "2026-11-06"
track: bug
category: ui
module: app/MeetingTranscriber/Sources/TranscriptionsView.swift
tags: [trash, confirmation, toctou, notion]
problem_type: ui
symptoms: A file back on disk after the dialog opened was moved unnamed; a failed export's Notion page was not mentioned
root_cause: Confirming passed only the job id and the action recomputed its files; the dialog read a field meaning a page may be opened as meaning a page exists
resolution_type: fix
---

## Problem
A Trash confirmation named the files that were on disk when the dialog opened, but confirming handed the action only the meeting's id, and the action worked out its files anew. A track moved away when the dialog opened was left out of the list; moved back before the click, it went to the Trash without having been named. Separately, the dialog's "the page in Notion stays" asked whether the row can open a page. That holds only for a completed export, so a failed export that had already made its page lost the line, and the test asserted the omission.

## What Didn't Work
Filtering the dialog's text by what the disk answered (the previous lesson on confirmation text) makes the words right at the moment they are shown. It says nothing about what the click does later. Reusing a field that exists for a different question also fails quietly: `notionPageURL` is nil on purpose before a completed export, so that nothing opens a partial page.

## Solution
The request keeps the paths the dialog named. On confirm the view reads the record and the disk once more through one shared answer, `TrashConfirmationText.files(of:record:audio:)`, and runs the action only when the named set still covers them. Otherwise nothing moves, the row stays as it was, a window message says so, and choosing the item again names the file. Fewer files than named goes ahead. `TranscriptionEntry.hasNotionPage` answers from the page id, kept from the moment the page exists, in the job and in the history record.

Re-presenting an updated alert from inside its own button was rejected: SwiftUI may clear the alert's binding before or after running the button, so a request set there can be wiped, and a ViewInspector test cannot tell the two apart.

## Prevention
For a destructive action behind a dialog, test the gap as well as the two ends: change the file on disk between opening the dialog and confirming it, with real files and a fake Trash. When a dialog says what stays or goes, name the question each input answers, and do not reuse a field that means "may be opened" for "exists".
