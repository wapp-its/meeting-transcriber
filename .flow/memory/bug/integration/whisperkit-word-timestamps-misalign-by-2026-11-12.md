---
title: WhisperKit word timestamps misalign by the prompt length with promptTokens
date: "2026-11-12"
track: bug
category: integration
module: app/MeetingTranscriber/Sources/PromptAlignedSegmentSeeker.swift
tags: [whisperkit, word-timestamps, vocabulary-prompt, alignment]
problem_type: runtime-error
symptoms: Prompted file decodes with word timestamps put segments seconds off and drop whole turns
root_cause: WhisperKit 1.1.1 keeps the prompt's alignment rows but returns tokens only from startoftranscript
resolution_type: fix
related_to: [bug/integration/hub-snapshot-keeps-a-damaged-cached-2026-10-06]
---

## Problem
Turning on WhisperKit word timestamps for file transcription broke timing for decodes with the vocabulary prompt. WhisperKit 1.1.1 feeds `<|startofprev|>` plus the prompt tokens before `<|startoftranscript|>` and writes one alignment row per fed token, but returns tokens only from `<|startoftranscript|>` on. `SegmentSeeker.addWordTimestamps` reads the rows from row 0, so every word was aligned one prompt length off: segments landed seconds off and whole turns went missing.

## What Didn't Work
Keeping segment-level times for prompted decodes (`wordTimestamps: promptTokens == nil`). The review rejected it: prompted files then keep the original bug, turns up to 30 s early after silence.

## Solution
`PromptAlignedSegmentSeeker` (installed on every pipe in `WhisperKitEngine.adoptPipe`) copies the alignment weights without the first `promptRows` rows (the trimmed prompt WhisperKit keeps, plus one for `<|startofprev|>`), then calls WhisperKit's own `addWordTimestamps`. An unexpected weights layout returns the segments unchanged (segment-level times). Shifting one row more or fewer measured worse on every track; the 0.2 to 2.5 s residual comes from the prompted decode's attention.

## Prevention
Any WhisperKit option that changes the decoder prefill (prompt, prefix tokens) must be checked against word alignment with a model-backed timing test. `WhisperKitWordTimestampsTests.testPromptedTurnAfterLongSilenceKeepsItsWordTimes` fails when WhisperKit fixes the offset upstream (rows would be dropped twice), which is the signal to delete the seeker.
