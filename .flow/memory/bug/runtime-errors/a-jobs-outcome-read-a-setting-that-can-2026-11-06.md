---
title: A job's outcome read a setting that can change during its protocol call
date: "2026-11-06"
track: bug
category: runtime-errors
module: app/MeetingTranscriber/Sources/PipelineQueue.swift
tags: [pipeline, settings, async, outcome, retention]
problem_type: runtime-error
symptoms: A failed protocol attempt was recorded as generation off after the provider was switched to None during the call
root_cause: The terminal transition re-read the live setting instead of what the stage found when it chose its generator
resolution_type: fix
related_to: [bug/runtime-errors/superseded-whisperkit-load-wrote-its-2026-10-07]
---

## Problem
A meeting's record says at its finish whether protocol generation was on for it, because a failed protocol still ends a job `.done` and only "generation off" lets a meeting without notes count as finished for automatic audio deletion. The first version read the live protocol setting at the terminal transition. Generation awaits a model for minutes, so a user who switched the provider to None during a call that then failed got `.finished(protocolExpected: false)`: a failed attempt passing for generation off.

## What Didn't Work
Reading the setting at the terminal transition was chosen because some paths reach `.done` without the protocol stage (a naming skipped with no generator, naming data lost at a restore), and a flag set only by the stage would stay at its default there. Deciding from the old state would not work either: a confirmed naming hops through `.generatingProtocol` synchronously even with no generator.

## Solution
`generateProtocol` keeps what it found when it chose its generator in `PipelineQueue.protocolGenerationOn`, on both branches. `noteOutcome` takes that value at the terminal state and asks the setting only when the stage never ran, which is the moment such a job passes the stage by. `removeJob` drops the entry for a job cancelled during the call.

## Prevention
A value that describes what happened during a job is captured when it happens, not read back from settings at the end: any `await` between the two lets the setting change. When a transition derives a fact from live settings, write the test that changes the setting from inside the mock call (`MockProtocolGen.onGenerate`), and test the paths that skip the stage next to it.
