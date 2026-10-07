---
title: Process terminationHandler kept a CLI run alive when Process.run() threw
date: "2026-10-07"
track: bug
category: performance
module: app/MeetingTranscriber/Sources/CLIProcessRunner.swift
tags: [process, retain-cycle, terminationHandler, transcript]
problem_type: performance
symptoms: a CLI run that could not start stayed in memory with its transcript for the life of the app
root_cause: "the handler capturing the run was cleared only in the exit callback, which never fires when the launch fails"
resolution_type: fix
---

## Problem
`CLIProcessRunner` installs `Process.terminationHandler` before `run()` (so an early exit is never missed) and the handler captures the run object, which owns the `Process`. The handler is the only thing that broke that cycle, and it fires only when the program exits. When `Process.run()` throws (a missing or non-executable CLI) the program never exits, so the run, its request and the whole meeting transcript on its stdin stayed in memory for the life of the app, one copy per failed protocol. On a timeout or the output cap the same hold lasted until the stopped program died. All three Codex review draws found it independently; the focused tests were green because none of them looked at what a run leaves behind.

## What Didn't Work
Clearing the handler inside the exit callback (`programExited`) covers only the path where the program actually exits. The launch-failure path never reaches it.

## Solution
`finish()`, the single terminal point of a run, sets `process.terminationHandler = nil` on every outcome (`app/MeetingTranscriber/Sources/CLIProcessRunner.swift`, `Run.finish`). The SIGKILL follow-up after a timeout captures only the `Process`, not the run.

## Prevention
For any object that hands a closure capturing itself to something it owns (a `Process` handler, a dispatch source, a timer), clear the closure in the one terminal function, not in the callback that may never come. To test it, give the request a `Data(bytesNoCopy:count:deallocator: .custom { ... })` whose deallocator fulfils an expectation, and require release after each terminal path (could not start, exited, timed out): `CLIProcessRunnerTests.testRunReleasesItsRequestOnceItHasEnded`.
