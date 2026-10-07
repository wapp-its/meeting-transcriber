---
title: Superseded WhisperKit load wrote its refusal under the newly selected model
date: "2026-10-07"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/WhisperKitEngine.swift
tags: [whisperkit, load-state, cancellation, settings]
problem_type: runtime-error
symptoms: Settings showed the old model's Hugging Face refusal under the new model's Load Model after a mid-load model switch
root_cause: "The download catch assigned lastLoadFailure unconditionally after applyModelVariant had cleared it, and the cancelled chain never ran the new model's attempt"
resolution_type: fix
---

## Problem
`WhisperKitEngine` gained `lastLoadFailure` so Settings can name a Hugging Face refusal under "Load Model". The Codex review found a stale-state path: a load parked in its download when the user switched models, whose owner was then cancelled, wrote the refusal it eventually received into `lastLoadFailure` after `applyModelVariant` had already cleared it for the new selection. The cancelled chain never ran the attempt for the new model that would have cleared it again, so Settings showed model A's refusal under model B's "Load Model" (spec R5: the line clears when the selection changes).

## What Didn't Work
Clearing the field in `applyModelVariant` and at the start of `performLoad` alone. Both clears happen before the superseded attempt's `catch` runs, and that `catch` assigned the failure unconditionally.

## Solution
Commit `fix(app): keep a superseded WhisperKit load from recording its refusal under the new model`: the download `catch` in `performLoad` records the failure only while the attempt's snapshotted `variant` and `origin` still equal the current selection (`app/MeetingTranscriber/Sources/WhisperKitEngine.swift`, the catch around the variant download). Pinned by `WhisperKitEngineSupersededLoadFailureTests` (a superseded load records nothing; a load for the current model still records its refusal), red before the fix (`XCTAssertNil failed: "tokenRejected"`), green after.

## Prevention
Any "last failure" or "last status" field on an engine whose loads can be superseded (`SingleFlight` owner cancelled, variant changed mid-load) must be written under the same selection check the load's success path uses; test the superseded path explicitly, not only the clear-on-change path. The engine already had a cancelled-load test; extend that shape with a failing attempt whenever a new per-load field is added.
