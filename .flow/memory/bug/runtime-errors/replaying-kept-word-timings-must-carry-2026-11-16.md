---
title: "Replaying kept word timings must carry the first run's mutes, timeline and tie o"
date: "2026-11-16"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/PipelineQueue+WordTimings.swift
tags: [rerun, word-timings, diarization, dual-track]
problem_type: runtime-error
symptoms: "Identify Speakers Again dropped mute lines, mislabelled a lone mic track, or swapped tied lines"
root_cause: "The relabel path reused the job's annotations and the topology-dependent rendering, not what the first run's rendering read"
resolution_type: fix
related_to: [bug/runtime-errors/a-job-without-its-mic-track-must-not-2026-11-15]
---

## Problem
Identify Speakers Again labels a meeting's kept transcript segments again instead of transcribing. The review found three cases where the result did not match the first run's words. Each came from something the first run's rendering depended on that the re-run's job did not carry:
- **Mute lines:** admission drops the mute times for a run on the mix or on one track, because a transcription of that audio would lose the far end's words. A run that only relabels the kept words lost the `[Mic muted …]` lines with them.
- **Timeline:** the kept segments are on the meeting's timeline, with the mic segments shifted by `micDelay`. A run on the microphone's track alone diarized it on its own timeline, so every voice was matched `micDelay` too early.
- **Tie order:** the labelling topologies break a tie of two segments starting at the same moment in different ways. The dual-track topology puts the call audio first; the fallback for a failed call audio puts the microphone first. So relabelling could swap two lines, and a transcript from an earlier build could have them in either order.

## What Didn't Work
The first version reused the job's own annotations and the standard rendering, on the assumption that the kept segments carry everything. Tests on the happy path (both tracks present, no tied starts) passed.

## Solution
- **Mute times:** admission keeps them when the run will reuse kept word timings (`PipelineQueue+Rerun.swift`, `reusesWords`).
- **Timeline:** the lone mic track's 16 kHz copy gets `micDelay` of silence prepended (`moveOntoTheMeetingsTimeline`).
- **Ties in new renderings:** every rendering orders tied segments by their order in the kept list (`inKeptOrder`).
- **Ties in older transcripts:** the reuse stage orders each tie as the current transcript has it (`inTheTranscriptsOrder`).

## Prevention
When a feature replays stored intermediate data in place of recomputing it, list every input the original rendering read: annotations, the timeline offset, the topology's tie-breaks. Then test the replay on each fallback source the admission allows, not only on the full set of tracks.
