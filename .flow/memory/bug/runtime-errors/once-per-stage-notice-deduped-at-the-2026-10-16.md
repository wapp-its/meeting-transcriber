---
title: Once-per-stage notice deduped at the source lost a later real notice
date: "2026-10-16"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift
tags: [notifications, dedupe, local-model, record-only]
problem_type: runtime-error
symptoms: A recording after a record-only hold paused the protocol without the paused notice
root_cause: The queue reported only the first deferral and the notice layer suppressed that one
resolution_type: fix
---

## Problem
The "protocol paused for your recording" notice was meant to post once per protocol stage, so the queue reported only the first deferral (`deferrals == 1`). The notice layer then held back that first report on purpose when record-only mode caused it (spec A21). A real recording that deferred the same job later was the second deferral, so nobody was told.

## What Didn't Work
Deduplicating at the event source: a once-only event plus a filter downstream means a filtered first event silently consumes the only notice.

## Solution
The queue reports every deferral (`PipelineQueue+LocalModel.swift`, `generateWaitingOutRecordings`); `LocalModelJobNotices` keeps `pausedJobs`, inserts only when it actually posts, and clears the job when it leaves `.generatingProtocol`. Pinned by `LocalModelOutcomeMappingTests.testARecordOnlyHoldPostsNoNotice` (record-only hold, then a recording, expects one paused notice).

## Prevention
When a notice is "once per X" and some instances are suppressed, deduplicate on what was posted, at the layer that decides to post. Test the suppressed-then-real sequence, not only each case alone. Related lesson from the same review: an effects spy for "Open Settings" hid that the live action never selected the tab; test the receiving view's handling of the request too.
