---
title: Hub snapshot keeps a damaged cached file whose download record matches
date: "2026-10-06"
track: bug
category: integration
module: app/MeetingTranscriber/Sources/HubTokenScopedWhisperKit.swift
tags: [whisperkit, huggingface, tokenizer, cache]
problem_type: integration
symptoms: Re-fetching a damaged tokenizer over the Hub cache returned the same broken bytes; the model stayed unloadable until the cache folder was deleted by hand
root_cause: ArgmaxCore HubApi.snapshot treats a download record naming the current commit as a cache hit and never reads the file
resolution_type: fix
---

## Problem
`HubTokenScopedWhisperKit` (the WhisperKit subclass that puts a loadable tokenizer in place with the app's own Hugging Face token) treated "the trial load of the cached tokenizer failed" as "fetch a fresh copy over it". The Codex review found that the fetch never replaced the damaged file: ArgmaxCore's `HubApi.snapshot` keeps a downloaded file whose `.cache/huggingface/download/<file>.metadata` record still names the current commit without reading the file, so the second trial load got the same damaged bytes and the model stayed unloadable until the user deleted the cache folder by hand. The spec's "overwriting a broken copy there" and the task's "broken copy → fetch and re-trial" acceptance were both stated and both broken.

## What Didn't Work
Calling `snapshot(from:matching:)` again for the three tokenizer files and relying on the Hub client to notice the damage. The client compares its download record to the remote commit, never the file contents, so a matching record is a cache hit whatever the bytes are.

## Solution
Commit `fix(app): replace a damaged cached tokenizer before fetching it again` adds `WhisperTokenizerCache.removeCachedTokenizer(in:)`, which deletes `config.json`, `tokenizer_config.json`, `tokenizer.json` and their `.metadata` download records from the first search path before the fetch, so the fetch writes a fresh copy (`app/MeetingTranscriber/Sources/HubTokenScopedWhisperKit.swift`, the fetch step of `ensureLoadable`). Pinned by `WhisperTokenizerCacheTests.testABrokenCopyInTheFirstSearchPathIsRemovedWithItsRecordsBeforeTheFetch`, red before the fix (all six files still present at fetch time), green after.

## Prevention
When a design says "fetch over a broken file" through the Hugging Face Hub client (ArgmaxCore `HubApi`, swift-transformers `HubApi`), write the test with a damaged file AND a matching `.metadata` record in place and assert the files are gone before the fetch runs. A plain "fetch happened" assertion passes while the cache hit hands the broken bytes back.
