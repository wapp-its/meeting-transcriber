---
title: Channel-health hold missed a sub-poll pause and the watchdog give-up after resum
date: "2026-10-14"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/ChannelHealthController.swift
tags: [channel-health, pause, watchdog, sampling, window]
problem_type: runtime-error
symptoms: A pause between two 100 ms polls left the silence windows running; a watchdog give-up during a pause posted Capture Channel Silent on the first resumed tick
root_cause: Sampled isPaused cannot show a transition between samples; ChannelFaultMonitor reports the watchdog flag before its window guard
resolution_type: fix
related_to: [bug/runtime-errors/pause-cut-drifted-across-repeated-2026-10-14]
---

## Problem
Task gh-46-pause-and-resume-a-recording.3 held the channel-health checks while a recording is paused by sampling `RecordingProvider.isPaused` on each 100 ms tick of `ChannelHealthController.applyTick` and resetting the monitors' windows at the first unpaused tick. Review found two gaps against R7 ("every check restarts from the resume, judging only post-resume conditions"). First, a pause that begins and ends between two polls is never seen, so the monitors keep their pre-pause windows: with silence through 29.9 s, a pause at 29.92 s and a resume at 29.96 s raised "Recording Appears Silent" 40 ms after the resume. Second, resetting `firstTickAt` does not hold the silent-track watchdog's rebuilds-exhausted report, because the unchanged `ChannelFaultMonitor` checks that flag before its elapsed-time window guard, so a watchdog give-up during the pause posted "Capture Channel Silent" on the first resumed tick even with both channels healthy.

## What Didn't Work
A sampled Boolean cannot represent a transition that completed between samples; and restarting a window inside the controller does nothing for a monitor arm that reports before consulting the window.

## Solution
`RecordingProvider` gained a required `pausesBegun: Int` (no protocol-extension default, since a default of 0 hides exactly this case); `DualSourceRecorder` counts each pause that takes effect, and `ChannelHealthController.holdWhilePaused` treats a changed count as both edges on that tick (app/MeetingTranscriber/Sources/ChannelHealthController.swift, DualSourceRecorder+Pause.swift). After a resume, the controller passes the watchdog flag to the fault monitor only once `min(energyAge, elapsedSinceResume) >= window`, so the report needs a whole window of post-resume silence; latches and the terminal "Capture Channel Lost" report are unchanged. Regression tests: `ChannelHealthPauseTests.testAPauseBetweenTwoTicksStillRestartsTheWindows`, two watchdog-after-resume tests, `DualSourceRecorderPauseTests.testOnlyAPauseThatTakesEffectIsCounted`.

## Prevention
When a controller holds checks on a sampled state, test the transition that fits between two samples (pause and resume with no tick in between). When a window is restarted, enumerate every arm of the downstream monitor that can report without consulting the window (here the watchdog flag) and cover each with a "raised during the hold, healthy after" test.
