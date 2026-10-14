---
title: Load offer 'Later' lost to a load already running for another model
date: "2026-10-14"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/WhisperKitModelChoice.swift
tags: [whisperkit, load-offer, concurrency, review-fix]
problem_type: runtime-error
symptoms: "Picking model B while model A still loads: the running load went on to B, so 'Later' did nothing; suppressing the question instead broke the ask-on-every-pick rule"
root_cause: The offer was decided from the engine's idle state only; the load loop re-read the selection and carried on without consulting the user's answer
resolution_type: fix
related_to: [bug/runtime-errors/async-probe-result-adopted-after-its-2026-10-09, bug/runtime-errors/superseded-whisperkit-load-wrote-its-2026-10-07]
---

## Problem
The load offer ("Load the new model now?") for a newly picked WhisperKit model was judged only from the engine's current state. When model A was still downloading or loading and the user picked model B, the running load went on to load B anyway, so "Later" was a no-op, and a first fix that suppressed the question while any load ran broke the task's rule that every pick of another model asks. The review (codex gpt-5.6-sol) found this chain across three rounds on `WhisperKitModelChoice.swift` and `WhisperKitEngine.swift`.

## What Didn't Work
Not asking while a load is in flight (`shouldOffer` returning false during a load): it hides the question exactly in the case where the user most needs to decide, and the running load still picks up the new selection on its next loop.

## Solution
"Later" is a deferral mark on the engine (`WhisperKitEngine.deferredSelection`, set by `WhisperKitModelChoice.offerLoad` as soon as the offer appears). `loadModel(stoppingAtDeferred:)` stops before loading a deferred selection for preload, settings and live-caption loads; a transcription's load ignores the mark; "Load now" and "Load Model" clear it. Commits `0fb6b35a`, `c9f22297`, `40eb15c8` on the spec branch; tests `WhisperKitModelChoiceTests.testLaterDuringALoadStopsItBeforeThePickedModel`, `testAPickStaysUnloadedWhileItsQuestionIsOpen`, `testATranscriptionLoadsADeferredModel`, `testAnExplicitLoadOverrulesLater`.

## Prevention
When a UI decision gates work that an in-flight task will otherwise perform on its own (a load loop re-reading the selection), test the decision with the work already running, not only from idle: a "picked while loading" case in the decision table catches it before review. CLAUDE.md's statement that `loadModel()` always ends loaded or failed now holds only for a transcription's load; the owner decides whether to update it (spec assumption A6).
