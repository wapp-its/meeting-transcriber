---
title: Core Audio PID translation folded a failed call into 'no process object'
date: "2026-11-14"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/AudioDeviceStatusProbe.swift
tags: [core-audio, error-handling, probe]
problem_type: runtime-error
symptoms: A failed tapped-process lookup read as 'uses no device' instead of Status unknown
root_cause: processObject returned nil for both an absent process object and a failed call; compactMap dropped both
resolution_type: fix
related_to: [bug/runtime-errors/a-deadline-checked-only-by-the-polling-2026-11-14, bug/runtime-errors/async-probe-result-adopted-after-its-2026-10-09]
---

## Problem
`MeetingMicrophoneProbe.RawReads.processObject` returned nil in two cases: when a PID has no Core Audio process object, and when the translation call failed. The Audio Devices probe dropped every nil with `compactMap`. A failed lookup therefore came back as a complete "uses no device" answer, and rows lost "Used by" without showing "Status unknown".

## What Didn't Work
Reusing the meeting microphone probe's skip-on-nil rule. That probe only needs to skip; a status display has to know a failure from an absence.

## Solution
`processObject` now returns `Reading<AudioObjectID?>`: `.value(nil)` when the PID has no process object, `.failed(status)` when the call failed. `AudioDeviceStatusProbe.meetingAppDevices` marks both sides incomplete on a failure, so those rows read unknown.

## Prevention
A read seam that folds an error and an absence into the same nil hides failures from every caller that has to report them. Keep the `OSStatus` in the seam's type, and give each probe one test fake where the translation itself fails.
