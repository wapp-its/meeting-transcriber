---
satisfies: [R1, R2, R3, R4, R5, R6]
---
# gh-213-turns-in-two-track-transcripts-start.1 Implement Turns in two-track transcripts start when they are spoken

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
WhisperKit file transcription now requests word timestamps, so each segment's start and end come from its first and last word; live captions keep segment-level options. A model without alignment data keeps segment-level times. With the vocabulary prompt on, the engine's `PromptAlignedSegmentSeeker` drops the prompt's alignment rows before WhisperKit aligns the words (WhisperKit 1.1.1 aligns them one prompt length off otherwise); an alignment layout it cannot shift keeps segment-level times.

Tests: a pure options test (file on, live off), pure tests for the prompt row count and the row shift, and two model-backed regressions on the synthetic `turn_after_silence_de.wav` (12 s of silence, then a turn at 12.0 s) with `openai_whisper-small`, without and with a vocabulary prompt, asserting start and end within 2 s. Base: the turn started at 0.0 s; prompted without the row correction it ended at 21.3 s.

Measured: unprompted turns within 0.5 s; prompted turns 0.2 to 2.5 s early on synthetic tracks (one longer track misses the 2 s bound by 0.5 s), against up to 30 s with segment-level times. No WER change on the quality fixtures.

stage: impl-review - SHIP (codex gpt-6-astra xhigh, round 3; rounds 1-2 NEEDS_WORK on the prompted alignment, fixed)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: d974a238995eef85d87a773f4317e54473e51b0a, 342d8ab00eed154a70201a49afbec31bcb84226c, d0a3d147a6841ef4f2a0a5abed0eb5d8a38b3d97, d3c811516f788661a6829fa46213b23b3e8480a3, 4adcb69828c990f669683285d15a0965349b8025, 3474edf93f4ed157ba7e1af6b1ddff48e0fbd140, 34928d7c5c9fdbaf55c238169b28571805ca0cb0
- Tests: swift test --filter 'WhisperKitWordTimestampsTests|WhisperKitEngineTests|WhisperKitVocabularyFlowTests|WhisperKitTranscriptionFailureTests|WhisperKitE2ETests' (58 passed)
- PRs: