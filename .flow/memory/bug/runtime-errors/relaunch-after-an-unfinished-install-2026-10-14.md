---
title: Relaunch after an unfinished install lost the build on offer
date: "2026-10-14"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/UpdateChecker+MtUpdate.swift
tags: [mt-update, relaunch, pending-record, update-checker]
problem_type: runtime-error
symptoms: "After Update did not finish, Install stayed refused until a check ran"
root_cause: Launch paths cleared the pending record without restoring its summary into in-memory state
resolution_type: fix
---

## Problem
`UpdateChecker` keeps the available mt-update build (`availableBuildSummary`) only in memory. An install that mt-update starts can outlive the app, so the next launch finds the pending-install record and reports the outcome. On the "did not finish" paths (reported at launch, or by the 30-second recheck), the launch cleared the record without taking its summary. The new instance had no summary of its own until a check ran, so Install stayed refused, although R7 says that checks and Install become available again. The codex impl-review reproduced it with a probe; the unit tests had only checked that the state went back to idle and that a check reached the installer.

## What Didn't Work
"Back to idle" was treated as the whole recovery. The live-exit path looked correct, because that instance still had its summary in memory, and that hid the gap on the relaunch paths.

## Solution
`finishInstall(_:installing:)` in `app/MeetingTranscriber/Sources/UpdateChecker+MtUpdate.swift` takes the summary of the build it tried to install. For a failed or unfinished outcome, it puts that summary back on offer. The live exit passes the summary it started with, and `resumeAfterLaunch` and the recheck load the record first and pass `pending.summary`. Regression asserts: `UpdateCheckerMtUpdateTests.testTheSameBuildWithMtUpdateGoneAtLaunchDidNotFinish` (retry without a check) and `testAnInstallStillRunningAtLaunchIsRecheckedUntilItHasGone`.

## Prevention
- When a requirement says "X is available again" after a restart, test the action itself in a fresh instance (`installNow` starts the installer), not only the state flag.
- In-memory state that a persisted record replaces across a relaunch must be restored from the record on every path that reads it, not only the path that wrote it.
