---
title: "A batch Trash action checked its confirmed files once, not before each move"
date: "2026-11-07"
track: bug
category: data
module: app/MeetingTranscriber/Sources/TranscriptionsView.swift
tags: [trash, selection, confirmation, toctou]
problem_type: data
symptoms: A later meeting's file that came back during the batch moved without being counted
root_cause: The stop check ran once for the batch; each Trash action recomputes its files when it runs
resolution_type: fix
related_to: [bug/data/a-confirmation-skipped-on-zero-treated-2026-11-07]
---

## Problem
The All Recordings selection moves several meetings to the Trash after one confirmation. The confirmation checked every meeting's files once, before the first move, then called each meeting's Trash action in turn. Each action works out its files anew, so a file of a later meeting that came back while an earlier meeting was moving went to the Trash without the dialog having counted it. The review reproduced it with temp folders and the fake Trash's `beforeMove` hook, for both Move Audio and Move Meeting.

## What Didn't Work
A single up-front check over the whole batch. It covers changes made while the dialog was open, but not changes made during the batch itself, because the earlier moves take time and other processes keep running.

## Solution
`TranscriptionsView.confirm` keeps the up-front check (nothing moves when a file came back while the dialog was open) and checks each meeting after the first again right before its own action. When that check fails, the batch stops before that meeting, the window says after how many meetings it stopped, and only the meetings acted on leave the selection. The first meeting is not read twice, as nothing has moved before it.

## Prevention
For any batch of destructive actions behind one confirmation, check each item right before acting on it, not only once for the batch. Test it with a hook in the fake Trash (or fake remover) that changes the next item's files while the current one moves, and assert the uncounted file stays.
