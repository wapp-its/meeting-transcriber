---
title: Test-started Task left a model helper running after an early test failure
date: "2026-10-16"
track: bug
category: test-failures
module: app/MeetingTranscriber/Tests/LocalModelRealModelTests.swift
tags: [xctest, teardown, concurrency, local-model]
problem_type: test-failure
symptoms: a failed real-model test left the helper holding the model's memory while later tests ran
root_cause: the generation ran in a fire-and-forget Task that no teardown cancelled or awaited
resolution_type: fix
---

## Problem
A real-model test started its generation in a fire-and-forget `Task` so it could watch the helper while it wrote. When the test failed or threw before the helper ended (a timeout waiting for output, a failed request), the test method returned and the task kept running. The helper went on holding the model's memory (about 17 GB) while the rest of the suite ran, until it finished or hit its own deadline. A probe that failed the test early confirmed it. Without the fix the helper was still alive after teardown.

## What Didn't Work
Relying on the success path. When the test passes, the generation has already ended, so nothing ever showed the leak. The existing teardown blocks stopped the HTTP server and the recording but not the generation.

## Solution
`GenerationRun` keeps its `Task` and offers `cancelAndWait()`; the test registers `addTeardownBlock { await generation.cancelAndWait() }` right after starting it. Cancelling the task reaches the gate's and the runner's cancellation handlers, which end the helper and confirm its exit, so teardown returns only once the process is gone (`app/MeetingTranscriber/Tests/LocalModelRealModelTests.swift`).

## Prevention
A test that starts work outside its own await chain (a `Task`, a child process) registers a teardown that cancels and awaits it, at the point where it starts the work. Prove it with a temporary early failure and a teardown registered before the work starts (teardown blocks run last in, first out), which then checks the process is gone.
