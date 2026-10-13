---
title: Async probe result adopted after its precondition lapsed; wedged read left no su
date: "2026-10-09"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/MicrophoneController+MeetingProbe.swift
tags: [concurrency, main-actor-hop, core-audio, probe]
problem_type: runtime-error
symptoms: a result in flight at mic give-up could still warn; a read still out at stop left no stop summary
root_cause: "adoption re-checked only the recording generation, and probes were counted at adoption instead of at dispatch"
resolution_type: fix
---

## Problem
The meeting-app microphone probe reads Core Audio off the main thread and adopts the result in a main-actor hop. The hop dropped a result only when its recording generation was stale, so a read still out when the microphone track gave up was still adopted: a second mismatch could post the warning about a microphone the recording no longer captured, and the menu hint stayed after the give-up. In the same change, probes were counted only when a result came back, so a read that never returned (the coreaudiod hang the off-main design exists for) left no stop summary at all.

## What Didn't Work
Checking eligibility (track running, tapped processes present) only before dispatch, and treating "same recording" as the whole adoption condition. Counting a probe at adoption looked equivalent to counting it at start until the wedged-read case was traced.

## Solution
`MicrophoneController+MeetingProbe.swift`: `adoptMeetingProbe` re-checks `attachment.recorderProvider()?.microphoneTrackActive == true` beside the generation, and the tick clears `meetingAppHint` once the track or the tapped processes are gone. `MeetingMicrophoneWarningPolicy.recordProbeStarted()` counts a read when it is dispatched, so the stop line reads `lastVerdict=none probes=1` for one still out. Tests: `testAResultStillOutWhenTheMicrophoneTrackGivesUpIsDropped` (red without the guard), `testAResultArrivingAfterItsRecordingStoppedChangesNothing`.

## Prevention
For any async result adopted on the main actor, list every condition that justified starting the work and re-check each at adoption, not only an identity token. Count work at the moment it starts when the summary has to explain work that never finished. Test with a blocked reader: block, change the precondition, unblock, assert nothing was adopted.
