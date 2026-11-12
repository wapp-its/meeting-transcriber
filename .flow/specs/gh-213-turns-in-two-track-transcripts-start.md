# Turns in two-track transcripts start when they are spoken

## Conversation Evidence

> user (turn 2, paraphrased): on the transcript review page the timestamps and the text do not match the audio; the same bug once existed in another of the owner's tools and was fixed there; can it be fixed here too?
> user (turn 3, paraphrased): only the start was checked: segment 2 carries the text of segment 1, segment 3 has text that does not match what is said, segment 9 roughly fits again, it gets better towards the end, speakers are mostly right; seen on a two-track recording.
> user (turn 3, selected): "A: App schreibt Segmentdatei (Empfohlen)"

## Goal & Context

<!-- Source: 20% user [paraphrase] / 65% measured in the session / 15% [inferred] -->

A two-track recording (call audio and microphone) is transcribed one track at a time. On each track, the other side's turns are silence. With segment-level timestamps only, WhisperKit starts a segment that follows a long silence where the previous segment ended, or at the start of its 30-second window, up to about 30 s before the words are spoken. After both tracks are merged, such a turn is stamped too early and sorts before the other speaker's turn, so the transcript text at a time is not what was said then. The owner saw this on a real recording when listening segment by segment [paraphrase].

What was measured (no meeting content was read; real-audio checks compared timings only):

- Synthetic two-track meeting (11 German turns from macOS `say`, 129 s, each track silent while the other speaks), per track, today's decoding options: 8 of 11 turn starts more than 2 s early with the Swiss German fine-tune `spert/flix-swissgerman-whisperkit` (8-bit), worst 19.9 s early; with the stock `openai_whisper-small`, for example a turn spoken at 95.0 s is placed at 67.4 s and one at 39.1 s at 20.0 s.
- The same tracks with word timestamps requested: every turn starts within 0.4 to 2.0 s of the truth (fine-tune) and within 0.5 s (stock small).
- A real 27-minute two-track recording: matching each exported line's words against a re-run with good timing put 59 of 80 lines within 3 s and 10 lines more than 10 s off (one 14 s early, one 20 s late).
- Word timestamps cost no measurable time: 296 s against 307 s for the 27-minute mix with the fine-tune.
- Ruled out as causes: a constant shift or drift of the whole timeline, decoder looping (WhisperKit resets the decoder context per window), the review page's playback, and the VAD trim (off in the affected install).

## Architecture & Data Models

- File transcription (recorded tracks, imported files, the mix of a single-source recording) builds WhisperKit decoding options from the language setting and the optional vocabulary prompt and transcribes the whole file. The dual-track path then shifts microphone segments by the recorder's measured delay, merges both tracks, assigns speakers from diarization, and the text export writes each turn's start.
- With word timestamps requested, WhisperKit aligns words from the decoder's cross-attention, moves each segment's start and end to its first and last word, and advances its seek point from the last word (WhisperKit 1.1.1 behaviour) [inferred].
- Live captions take a separate path that transcribes short sample buffers and returns joined text without timestamps.

## API Contracts

- Decoding options for file transcription: word timestamps on; language, language detection and prompt tokens as today.
- Decoding options for live captions: unchanged.
- The transcript segment shape (start and end in seconds, text, speaker) is unchanged; segments with empty text are still dropped.

## Edge Cases & Constraints

- A model that yields no word timings (no alignment data) keeps segment-level times; transcription must not fail because of it [inferred].
- Word alignment can produce a segment without text over a silence; it must not reach the transcript [inferred].
- Long recordings: no slowdown beyond measurement noise was seen on 27 minutes; a clearly slower run on long audio is a regression [inferred].
- Parakeet takes its timings from its own token timings and is not affected.

## Acceptance Criteria

- **R1:** In a file transcribed with WhisperKit, a speech turn that follows at least 10 s of silence on its track starts in the transcript within 2 s of when it is spoken (today it can start up to about 30 s early). Errors: no error surface beyond the existing transcription errors. [paraphrase]
- **R2:** File transcription requests word timestamps, and each transcript segment's start and end come from its first and last word whenever word timings exist. Errors: when the model returns no word timings, segments keep their segment-level times and the transcription completes without an error. [inferred]
- **R3:** Live captions keep their current decoding options, without word timestamps. Errors: no error surface beyond R2. [inferred]
- **R4:** A segment that has no text after word alignment does not appear in the transcript. Errors: no error surface beyond R2. [inferred]
- **R5:** A regression test runs a synthetic track with a speech turn after a long silence through the WhisperKit engine's file path with the test suite's small stock model and asserts the R1 bound; it fails on the base by the start error. A pure test pins the file-versus-live decoding options. Errors: no error surface beyond R1. [inferred]
- **R6:** The transcription architecture doc states in one line that file transcription uses word timings and why (silence on a single track pulls segment starts early). Errors: none. [inferred]

## Boundaries

- No machine-readable segment file next to the transcript text in this spec; the owner picked that route before the cause was known, and it is a separate follow-up [paraphrase].
- Parakeet, diarization, the dual-track merge, the text export format and the VAD setting stay as they are [inferred].
- Bracketed hallucinations over silence (such as "[Musik]") are not this spec [inferred].

## Decision Context

- **D1 · Fix the text-versus-audio mismatch in the app.** why: the owner asked whether it can be fixed here as it was in another tool (paraphrased) · status: active [owner-stated 2026-11-12]
- **A1 · Request word timestamps for file transcription instead of chunking or trimming silence.** flip at: the file-transcription decoding options · test: the R5 regression test · alternatives: WhisperKit's VAD chunking (measured: 8 of 11 synthetic turns still more than 2 s early), the app's VAD trim (not measured per track), segment-level times as today · status: active [agent-inferred 2026-11-12]
