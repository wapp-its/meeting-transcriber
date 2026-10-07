---
title: Whole-capture level balance kept after the meeting-end cut truncated the mix
date: "2026-10-07"
track: bug
category: data
module: app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift
tags: [level-balance, recording-cut, audio-mix]
problem_type: data
symptoms: A cut-back recording's mix kept gains measured on the discarded countdown tail
root_cause: stop() balanced the whole capture; RecordingCut only truncated the balanced mix
resolution_type: fix
---

## Problem
The speech-level balance ran inside `DualSourceRecorder.stop()`, over everything captured. A detected meeting that ends through the "meeting seems to have ended" question is stopped first and cut back afterwards (`WatchLoop.cutBack` -> `RecordingCut.apply`), and the cut only shortened the already balanced mix. Up to two minutes of countdown tail, which is thrown away, therefore set the gains of the meeting that is kept: loud talk in the room after the call turned the own voice down. In the test fixture the two sides ended 33 dB apart instead of within 6 dB.

## What Didn't Work
Wiring the setting only into the places that write a mix (`stop()`, crash recovery). Any whole-file analysis that runs before a later truncation step measures audio the saved file no longer contains.

## Solution
`RecordingResult.levelBalanced` records whether the two tracks were mixed with the balance (set by `buildRecording`). After a successful cut, `cutBack` calls `RecordingCut.remixBalanced`, which mixes the cut tracks again with `AudioMixer.mix(..., levelBalance: true)` into a hidden sibling and renames it over the mix; a failure leaves the cut mix whole and logs `recording_cut_remix_failed`. Single-track and unbalanced mixes are only cut, as before.

## Prevention
When a step derives values from a whole recording (gains, levels, statistics), list every later step that changes the recording's extent (cut, trim, crash rescue) and check the derived values are recomputed on what is kept. Test with a discarded stretch that would move the derived value a lot.
