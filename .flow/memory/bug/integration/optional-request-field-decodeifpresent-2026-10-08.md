---
title: "Optional request field: decodeIfPresent reads explicit null as absent"
date: "2026-10-08"
track: bug
category: integration
module: app/MeetingTranscriber/Sources/RecordStatusDTO.swift
tags: [codable, automation-api, json, validation]
problem_type: integration
symptoms: POST /v1/record with scope:null was accepted and started a recording instead of 400
root_cause: decodeIfPresent returns nil for both a missing key and an explicit JSON null
resolution_type: fix
related_to: [bug/integration/custom-command-trimmed-its-model-value-2026-10-07]
---

## Problem
The `POST /v1/record` body gained an optional `scope` field. The decoder read it with `decodeIfPresent`, which returns nil both for an absent key and for an explicit JSON `null`. A client sending `{"action":"start","scope":null}` was therefore accepted as a plain start and recording began, although the documented contract answers 400 for any supplied scope other than `"any"` and for a scope on any action other than `stop`. Three independent review draws found it; the author's own tests only covered unknown string values and a scope on the wrong verb.

## What Didn't Work
Treating `null` as "no scope" by design ("it can never be read as any"). That reasoning holds for the `any` guarantee but not for the 400 promise: a present key with a null value is a supplied scope.

## Solution
Check the key's presence and decode a present value non-optionally (`container.contains(.scope) ? try container.decode(RecordScope.self, forKey: .scope) : nil` in `app/MeetingTranscriber/Sources/RecordStatusDTO.swift`), so an explicit null fails like an unknown value. Payload tests now cover `start`/`toggle`/`stop` with `null`, and the route test posts `{"action":"start","scope":null}` and expects 400 with nothing applied.

## Prevention
Whenever a request body gains an optional field whose presence changes behaviour, add the explicit-`null` case to the decoding tests next to the "unknown value" and "wrong verb" cases. In Swift's `Codable`, `decodeIfPresent` is only right when null and absent are meant to be the same thing.
