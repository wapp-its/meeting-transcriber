---
title: First-match helper prefix filed a prefix-related added app under another app's k
date: "2026-10-13"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/MicInputDetector.swift
tags: [detection, added-apps, identity-key, bundle-id]
problem_type: runtime-error
symptoms: "An added app whose bundle ID extends another added app's (com.acme.meet.beta vs com.acme.meet) was detected, cooled down, denied and kept alive under the other app's key"
root_cause: "patterns.first(where: matches) with helper-prefix matching returned the first pattern added, not the most specific one, in both checkOnce and isMeetingActive"
resolution_type: fix
---

## Problem
`MicInputDetector.checkOnce` picked the first pattern whose bundle ID matched a microphone-holding process, and added apps match helpers by prefix (`<bundleID>.*`). Two added apps with prefix-related bundle IDs, `com.acme.meet` and `com.acme.meet.beta`, both shown as "Meet", therefore shared one identity: the beta app's microphone use was detected, cooled down, denied and kept alive under the first app's key. The review's correctness draw found it after the identity key had been threaded through every piece of per-app state; the key was right, the pattern selection in front of it was not.

## What Didn't Work
Fixing only the selection in `checkOnce` left `isMeetingActive` matching the beta process against the first app's helper prefix, so the regression test's liveness assertion stayed red.

## Solution
`MicPattern.matchLength(bundleID:)` returns the length of the longest bundle ID a process is or is a helper of, and `MicInputDetector.mostSpecificPattern(for:)` picks the pattern with the longest match; both `checkOnce` and `isMeetingActive` go through it (`app/MeetingTranscriber/Sources/MicInputDetector.swift`, commit a4d2e4ac). An exact bundle ID always outranks another pattern's helper prefix, and an app's own helper still belongs to it.

## Prevention
When one process can match several patterns, decide the owner by specificity in one shared helper and test both the detection and the liveness path with prefix-related IDs (`MicInputDetectorTests.testPrefixRelatedAddedAppsAreFiledUnderTheMostSpecificBundleID`).
