---
title: A new CLI flag can fail on an old CLI with a wording the update hint misses
date: "2026-11-12"
track: bug
category: integration
module: app/MeetingTranscriber/Sources/CommandProtocolGenerator.swift
tags: [codex, cli-compat, update-hint, error-mapping]
problem_type: integration
symptoms: "Codex too old for --disable plugins failed with a bare exit code, no update hint"
root_cause: the hint matched only 'unexpected argument'; Codex reports unknown features as 'Unknown feature flag'
resolution_type: fix
related_to: [bug/integration/custom-command-trimmed-its-model-value-2026-10-07]
---

## Problem
The Codex preset gained `--disable apps` and `--disable plugins`. A Codex CLI without one of those features stops before the run with `Error: Unknown feature flag: <name>` on stderr, exit 1 and no JSON events. The update-hint mapping only matched `unexpected argument` (the wording for an unknown option), so an older Codex failed with a bare exit code instead of the promised update hint.

## What Didn't Work
Assuming every "CLI too old" failure uses the option parser's wording. Codex validates `--disable <feature>` names itself, after argument parsing, with its own message.

## Solution
`CommandProtocolGenerator.codexTooOldWordings` lists both wordings (`unexpected argument`, `Unknown feature flag`), and `codexFailureReason` maps either to `codexUpdateHint`, whose text stays unchanged. A table case in `CommandProtocolGeneratorTests.testCodexFailureReason` pins the unknown-feature wording.

## Prevention
When a preset or launch adds an option to a third-party CLI, run that CLI once with a bogus value of the same kind (an unknown flag and an unknown feature name). Map every wording it prints for "too old" to the same hint, with one test case per wording.
