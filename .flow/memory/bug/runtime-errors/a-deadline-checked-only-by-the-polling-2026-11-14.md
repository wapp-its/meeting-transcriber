---
title: A deadline checked only by the polling tick lets an overdue result through
date: "2026-11-14"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/AudioDevicesWindowReader.swift
tags: [concurrency, deadline, core-audio, async-probe]
problem_type: runtime-error
symptoms: A reading returned after its 2 s deadline but before the next tick was shown as current
root_cause: Only the periodic tick set the late flag; adoption did not check elapsed time
resolution_type: fix
related_to: [bug/runtime-errors/async-probe-result-adopted-after-its-2026-10-09, bug/runtime-errors/launch-time-task-loads-race-restored-2026-10-14, bug/runtime-errors/load-offer-later-lost-to-a-load-already-2026-10-14]
---

## Problem
The Audio Devices window's reader gives a Core Audio reading 2 s before its rows turn unknown. Only the 100 ms tick checked that deadline. A reading that came back after 2 s but before the next tick was adopted as current: the rows showed real marks and `/state` reported a non-null `selfRunningInput`.

## What Didn't Work
A `late` flag that only the periodic tick sets. The result's main-actor hop can run before that tick, so the flag is still false when the result arrives.

## Solution
The deadline is checked when the result comes back as well (`AudioDevicesWindowReader.adopt`, `isOverdue`). An overdue result clears its rows to unknown and is dropped, and the next reading answers them.

## Prevention
Any timeout enforced by a polling loop has to be checked again at the point where the result is used. Test it with an injected clock: advance past the deadline, then release the held read without a tick in between, and assert that a later reading is the one adopted.
