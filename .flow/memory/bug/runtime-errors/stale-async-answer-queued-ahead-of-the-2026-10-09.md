---
title: Stale async answer queued ahead of the settings observer passed a generation che
date: "2026-10-09"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/RemoteVocabularyController.swift
tags: [observation, main-actor, stale-result, generation, remote-vocabulary]
problem_type: runtime-error
symptoms: An answer fetched with the old access token replaced the cached vocabulary after the token changed
root_cause: "withObservationTracking onChange only enqueues the observer Task, so an already-queued fetch continuation ran before the generation moved"
resolution_type: fix
---

## Problem
`RemoteVocabularyController` dropped a check's answer when its generation counter had moved. The counter moves in the settings observer, and `withObservationTracking`'s `onChange` only enqueues a `Task { @MainActor in ... }`. A fetch that had already finished had its continuation queued on the main actor before a token change was made, so it ran first, passed the generation check and replaced the cached vocabulary with what the old token fetched. When the new token's check then failed, the old token's copy stayed in use. The Codex review found it; a test reproduced it deterministically.

## What Didn't Work
A generation counter alone, bumped and paired with cancelling the in-flight task inside the observer. Cancelling does nothing for an answer that has already been delivered and is waiting in the main-actor queue, and the observer's own Task is queued behind it.

## Solution
At adoption time, compare the values the check started with against the live settings, read synchronously: source, normalized address and the token revision counter. The generation stays as well, for an A→B→A change the observer has already processed. See `RemoteVocabularyController.describesSettings(_:address:tokenRevision:)` in `app/MeetingTranscriber/Sources/RemoteVocabularyController.swift`. It is pinned by `RemoteVocabularyControllerTests.testAnAnswerQueuedAheadOfATokenChangeDoesNotLand`, which went red before the fix (6-byte stale body stored) and green after.

## Prevention
For any `@Observable` settings consumer that discards stale async results, assume the observer runs after every job already queued on the main actor. Guard adoption on the current settings values, not only on state the observer updates. To reproduce in a test, resume a held fake fetch, then mutate the setting in the same synchronous main-actor turn. The answer is then queued ahead of the observer's Task.
