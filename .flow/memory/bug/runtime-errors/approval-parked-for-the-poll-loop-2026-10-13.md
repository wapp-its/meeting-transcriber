---
title: Approval parked for the poll loop survived Stop Watching with its options
date: "2026-10-13"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/WatchLoop+Consent.swift
tags: [consent, watch-loop, lifecycle, protocol-options]
problem_type: runtime-error
symptoms: "A restarted watch loop recorded on an answer given before watching stopped, carrying its template and background"
root_cause: "declineParkedConsent returned early when no question was open, so an approval already parked for the next poll was never cleared"
resolution_type: fix
---

## Problem
An answer to the recording prompt lands in `finishConsent`, which parks the approval in `approvedConsentMeeting` for the poll loop to take on its next iteration (up to one poll interval later). `declineParkedConsent`, run by Stop Watching and by a manual start, returned early when no question was open, so an approval already parked survived both. A restarted loop then recorded on an answer given to the loop that stopped, and once the approval carried "Record with Options…" choices (template and background), those rode along into the new recording.

## What Didn't Work
Clearing the new option fields in `clearConsentState()` alone: that function only ran while a question was still open, so the parked approval and its options were never cleared on that path.

## Solution
`declineParkedConsent` in `app/MeetingTranscriber/Sources/WatchLoop+Consent.swift` now always calls `clearConsentState()` and resolves the notifier only while a prompt is open. That matches `finishConsent`'s own rule that an answer landing after watching stopped records nothing. Regression test: `WatchLoopConsentOptionsTests.testAnApprovalWaitingForThePollLoopIsDroppedWithItsOptionsWhenWatchingStops`, which uses a 0.3 s poll interval so the approval stays parked long enough to stop in between.

## Prevention
State handed from an out-of-band answer to a polling loop has two windows to drop it in: while the question is open, and after the answer is parked but before the loop takes it. Test both when a lifecycle step (stop, manual start) must drop the handoff, and slow the poll in the test so the second window is wide enough to hit.
