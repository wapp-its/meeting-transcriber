---
title: A job without its mic track must not keep the mic's mute times
date: "2026-11-15"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/PipelineQueue+Rerun.swift
tags: [mic-mute, rerun, single-source, pipeline]
problem_type: runtime-error
symptoms: far-end speech dropped from a mix transcription; run failed as muted throughout
root_cause: mute times kept on a job that transcribes the mix or call audio
resolution_type: fix
related_to: [bug/runtime-errors/a-jobs-outcome-read-a-setting-that-can-2026-11-06]
---

## Problem
A job built outside the recorder (a re-run rebuilt from a finished meeting) collapsed a recorded call that had lost one of its two tracks into a single-source job, but kept the call's mic mute times. The single-source transcription stage applies mute times to whatever it transcribes, so on the mix it dropped what the far end said during a mute, and a mic muted throughout failed the run with "nothing to transcribe".

## What Didn't Work
Carrying every run input over unchanged: mute times are only valid for a job whose transcribed audio is the microphone (two tracks, or a recording that never had a call-audio track). The stage's comment states the invariant, but nothing enforces it at job construction.

## Solution
`PipelineQueue.rerunJob` empties the mute times when the run has no call-audio track but the record lists one (`PipelineQueue+Rerun.swift`), the same rule `RecordingSidecar.micMuteIntervals(app:mic:)` applies to a reimport. Regression test: `PipelineQueueRerunRunTests.testARecordedCallsRerunWithoutItsMicTrackKeepsWhatTheFarEndSaidDuringAMute`.

## Prevention
Every new place that builds a `PipelineJob` with `micMuteIntervals` must decide which audio the job transcribes: a mix or call-audio single source gets none. Test a constructor with a missing mic track and a mute over speech. The same review also found that an engine picked per job must reach every engine-keyed tag (stage timings), not only the transcription call.
