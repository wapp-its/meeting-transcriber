---
title: Provider error text shown in a regeneration result could echo meeting content
date: "2026-10-13"
track: bug
category: security
module: app/MeetingTranscriber/Sources/ProtocolRegeneration.swift
tags: [privacy, protocol-generation, error-messages, R9]
problem_type: security
symptoms: "A failed regeneration showed and notified the endpoint's error body, which can repeat the transcript and background"
root_cause: ProtocolError.httpError carries the endpoint's error body verbatim and its localizedDescription was surfaced
resolution_type: fix
---

## Problem
The protocol regenerator turned a provider failure into `error.localizedDescription` and showed it in its window, put it in the "Protocol Not Regenerated" notification and logged it. `ProtocolError.httpError(code, body)` carries the OpenAI-compatible endpoint's error body verbatim, and an endpoint can echo the request it rejected, which holds the transcript and the background info. So a failed run could put meeting content on the lock screen and into the diagnostic log, which R9 of the protocol-templates spec forbids.

## What Didn't Work
Trusting the pipeline's comment in `PipelineQueue.generateProtocol` that every `ProtocolGenerating` error message is content-free. That holds for the CLI generators, but not for `httpError`. The pipeline gets away with it only because it adds a fixed warning to the job and never shows the error text to the user.

## Solution
`ProtocolRegenerationError.generationFailed` carries no detail and reads one fixed sentence ("Protocol generation failed, so nothing was replaced."). The log names only the error's type (`app/MeetingTranscriber/Sources/ProtocolRegeneration.swift`, the `catch` around `generator.generate`). `ProtocolRegeneratorTests.testAThrowingGeneratorChangesNoFileAndRepeatsNothingItSaid` uses a generator that throws `httpError` with the background and transcript in its body, and checks that neither reaches the phase or the notification.

## Prevention
Never surface a provider error's `localizedDescription` in user-visible text, a notification or a `.public` log line. Map it to a fixed sentence, and log the type. A test for any new provider-failure path should throw an error whose text contains the request's content and assert it appears nowhere.
