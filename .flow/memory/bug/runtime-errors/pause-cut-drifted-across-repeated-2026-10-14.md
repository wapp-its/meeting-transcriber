---
title: Pause cut drifted across repeated pauses and lost a paused-first-buffer gap
date: "2026-10-14"
track: bug
category: runtime-errors
module: tools/audiotap/Sources/CapturePauseTimeline.swift
tags: [audiotap, pause, alignment, timeline-anchor, rounding]
problem_type: runtime-error
symptoms: Two tracks drifted apart by up to 6.4 frames over 20 pauses; a track first heard inside a pause lost its post-resume gap
root_cause: Whole-frame cuts vs exact-seconds clock accumulated per-boundary rounding; a fully paused buffer never set the TimelineAnchor
resolution_type: fix
---

## Problem
The pause timeline for AudioTapLib (task gh-46-pause-and-resume-a-recording.1) cut the paused frames out of every buffer before conversion and passed its own alignment proof, but three independent review draws found two alignment defects the proof did not cover. First, a buffer whose frames all lie inside a pause wrote nothing and therefore never set the track's `TimelineAnchor`; a track first heard inside a pause that then stopped delivering until after the resume lost the whole unpaused gap (16,000 frames at 16 kHz) because its first written buffer became position zero. Second, each cut removes whole input frames while the recording clock subtracts the exact paused time, so every pause boundary leaves up to one frame of difference, and with boundaries at the same sub-frame phase the differences added up: 20 pauses moved the app track 5.8 to 6.4 output frames while the microphone stayed under one, beyond the spec's one-frame alignment tolerance.

## What Didn't Work
The original alignment test used pauses at "round" host times and a single track phase, so the per-boundary rounding error cancelled or stayed below a frame, and no test placed a track's first buffer entirely inside a pause. `TimelineAnchor` could not have absorbed the drift anyway: it only inserts silence for a track that is behind, never trims a track that ran ahead, and the live sink gets no gap fill at all.

## Solution
`TimelineAnchor.anchorIfUnset(hostSeconds:)` (tools/audiotap/Sources/TimelineAnchor.swift) sets the origin with nothing written; both handlers call it when a buffer yields no frames to write (AppAudioCapture+Resampling.swift, MicCaptureHandler+Write.swift). A new per-track `CapturePauseCutter` (tools/audiotap/Sources/CapturePauseCutter.swift) takes over the cut from `keptFrameRanges`, carries the difference between the exact paused seconds (`CapturePauseTimeline.pausedSeconds(from:to:)`) and the frames cut, and settles it at the next piece after a seam: drop that piece's first frame when ahead, repeat it once when behind. Each track stays within half an input frame of the recording clock; file and live sink get the same pieces. Regression tests: `CapturePauseAlignmentTests.testATrackFirstHeardInsideAPauseKeepsTheGapAfterTheResume` and `testRepeatedPausesOnSubFrameBoundariesDoNotAddUp` (20 pauses, three sub-frame phases, both tracks within one 16 kHz frame of their unpaused reference and of each other), plus `CapturePauseCutterTests`.

## Prevention
When a timeline is edited in two domains at once (exact seconds on a clock, whole frames in a buffer), test repeated edits at a fixed sub-frame phase, not round times, and assert the cumulative drift, not a single boundary. For any "first buffer" anchoring, add the case where the first buffer contributes nothing to the file (fully paused, converter returned no output) and a delivery gap follows. Measure both tracks against an unpaused reference run of the same driver, including the live sink, which has no gap fill to hide a drift.
