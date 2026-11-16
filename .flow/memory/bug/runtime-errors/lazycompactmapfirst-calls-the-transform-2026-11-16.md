---
title: lazy.compactMap(...).first calls the transform twice and can trap
date: "2026-11-16"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/MicInputDetector.swift
tags: [swift, lazy, detector, crash]
problem_type: runtime-error
symptoms: "Fatal error: Unexpectedly found nil while unwrapping an Optional value in Swift/FlatMap.swift"
root_cause: first on a lazy compact-map collection evaluates the transform for startIndex and again for the subscript; a changing answer traps
resolution_type: fix
related_to: [bug/runtime-errors/first-match-helper-prefix-filed-a-2026-10-13]
---

## Problem

`CompositeMeetingDetector.rankedWindowTitle(for:)` returned `detectors.lazy.compactMap { $0.rankedWindowTitle(for: meeting) }.first`. On a collection, `first` of a lazy compact-map finds the start index by calling the transform, then reads that index by calling it again and force-unwrapping. The transform read a fresh Teams window list each time, so a window that closed between the two calls made the second call return nil and the standard library trapped (`Swift/FlatMap.swift: Unexpectedly found nil while unwrapping an Optional value`), which would have crashed the app during a recording. Stable answers still cost two window-list reads per poll.

## What Didn't Work

The lazy chain looked like a one-call "first non-nil answer". Tests with a stub that always answered the same passed, because both calls agreed.

## Solution

A plain loop asks each detector once and returns the first non-nil answer (`app/MeetingTranscriber/Sources/MicInputDetector.swift`, `CompositeMeetingDetector.rankedWindowTitle(for:)`). The regression test `TeamsWindowTitleRankTests.testTheCompositeDetectorAsksTheAnsweringStrategyOnce` uses a detector that answers once and then nil; it trapped before the fix.

## Prevention

Never put a call with side effects or changing answers (a window list, a clock, I/O) inside `lazy.compactMap`/`lazy.filter` followed by `.first`. Use a loop, or `first(where:)` on the eager result. A test double for such a call should answer differently on its second call, so a double evaluation shows.
