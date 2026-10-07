---
title: "Custom command trimmed its {model} value before substituting it"
date: "2026-10-07"
track: bug
category: integration
module: app/MeetingTranscriber/Sources/CommandProtocolGenerator.swift
tags: [placeholder, substitution, custom-command, validation]
problem_type: integration
symptoms: a model with surrounding spaces reached the program changed
root_cause: one normalised copy served both the blank check and the substitution
resolution_type: fix
---

## Problem
The custom command provider trimmed its `{model}` setting before substituting it into the argument list. A model value with surrounding spaces therefore reached the program changed, although the spec promises that a placeholder value arrives as one unchanged argument. Both Codex review draws that completed found it independently; the no-shell test was green because its model value had no surrounding whitespace.

## What Didn't Work
Normalising the value once at the top of `generate()` and using that one copy for both the blank check and the substitution.

## Solution
`CommandProtocolGenerator.generate` substitutes `model` as stored; `CommandTemplate.validate` trims only to decide whether the value counts as blank (`app/MeetingTranscriber/Sources/CommandProtocolGenerator.swift`, `generate`).

## Prevention
When a spec says a user value passes through unchanged, normalise only a throwaway copy for validation and pass the raw value on. Pin it with a test whose value carries surrounding whitespace next to the shell metacharacters (`CommandProtocolGeneratorTests.testArgumentsReachTheProgramUnchangedAndAreNeverExecuted`).
