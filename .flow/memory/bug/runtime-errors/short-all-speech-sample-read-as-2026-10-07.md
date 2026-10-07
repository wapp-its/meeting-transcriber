---
title: Short all-speech sample read as unmeasurable by a percentile noise floor
date: "2026-10-07"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/LevelBalance.swift
tags: [level-balance, noise-floor, naming-dialog, estimator]
problem_type: runtime-error
symptoms: A naming-dialog voice sample that is speech throughout played unbalanced (gain 0 dB)
root_cause: "The noise floor was the 10th percentile of the sample's own frames, which with no pause lies inside the speech"
resolution_type: fix
---

## Problem
The speech-level estimate takes its noise floor from the 10th percentile of the frames it is given and counts a frame as speech only 10 dB above that. A naming-dialog voice sample is a diarized segment, usually speech from start to end, so its own 10th percentile sat inside the speech: no frame cleared the margin, the sample read as not measurable and played unchanged. A quiet own voice at -40 dBFS stayed at -40. A probe over the repo's speech fixtures found 30 of 75 such 1.5-2 s cuts unmeasurable.

## What Didn't Work
The first version's tests cut 3 s with only 1.5 s of speech, so the cut carried its own pause and the estimator found a floor. That test shape hid the defect; the reviewer (impl-review round 1) caught it.

## Solution
`LevelBalance.measure` and `balance` take a `noiseReference: [Float] = []`; when non-empty, the noise floor is the 10th percentile of the reference's frames instead of the samples' own. `SpeakerNamingView.playbackSnippet` passes the whole decoded file it cuts from, whose pauses carry the same room tone. The mix passes nothing, so a track measures exactly as before. SwiftLint's `discouraged_optional_collection` rejects `[Float]?`; the empty-array default is the codebase convention.

## Prevention
A percentile-based noise floor needs pauses in its input. When reusing a track-level estimator on a short cut, test with a cut that is the signal from start to end (no pause of its own) and a reference that holds the background; a test cut that contains its own pause cannot fail for this.
