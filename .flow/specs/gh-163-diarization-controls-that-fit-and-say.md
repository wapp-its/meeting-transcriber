# Diarization controls that fit and say what they do

## Conversation Evidence

> owner (paraphrased, 2026-10-16): the speaker naming dialog opens too small, so texts such as the speaker count are not fully visible.
> owner (paraphrased, 2026-10-16): the dialog said the method caps at 4 speakers, but the recording came back with more than 4.
> owner (paraphrased, 2026-10-16): does the number of speakers have any effect, and does changing it make sense?
> owner (paraphrased, 2026-10-16): the labels are confusing; all methods run offline, so why is only one called "Offline"?
> owner (paraphrased, 2026-10-16): can custom diarization models be used, as for the LLM and transcription?
> owner (selected, 2026-10-16): "1A" (hide the count for Sortformer and Nemotron 3), "2A" (describe what each method does), "3A" (no custom diarization models now).
> owner (paraphrased, 2026-10-20): in the mockup the Re-run button was too small and its text wrapped; the rest is OK.
> issue #163: six problems: the re-run row does not fit; the cap hint is wrong for two-track recordings; the count does nothing in Sortformer and Nemotron 3 mode; in "Offline" mode the count applies to the call audio only; "Offline" is misleading; the method order differs between Settings and the dialog.

## Goal & Context

<!-- Source: 40% issue #163 / 40% [paraphrase] / 20% [inferred] -->

The diarization method (how the app tells speakers apart) is chosen in Settings › Speakers › Diarization and can be changed per recording in the Name Speakers dialog ("Wrong count?" / Re-run). Both places mislead today:

- The dialog's re-run row is wider than the dialog, so its texts are cut off.
- Sortformer and Nemotron 3 ignore the speaker count, yet both places offer one. A re-run with another count and the same method gives the same result.
- The "caps at 4 / 8 speakers" hint is a limit per audio track. A recorded call is two tracks (the call audio and the user's microphone), diarized separately, so a call can legitimately return more speakers than the hint says.
- In "Offline" mode the count forces exactly that many voices on the call audio only; the microphone side is always detected automatically. The UI reads as if the count were the whole meeting, so a user who enters the total over-splits the remote side.
- "Offline" is the speech library's internal name for its clustering method. All three methods run on the Mac.
- The three methods are listed in a different order in Settings and in the dialog.

Who it is for: anyone who names speakers after a meeting or picks a diarization method. Why now: the owner was misled by exactly these points on a real recording.

Upstream check (2026-10-16): the original project has no open issue or pull request about these controls. Its Nemotron 3 mode is still an open pull request there, so only the Standard and Sortformer parts would apply upstream.

## Architecture & Data Models

<!-- Source: 20% [paraphrase] / 80% [inferred] -->

- `DiarizerMode` keeps its three cases and their stored raw values (`offline`, `sortformer`, `nemotron`). It gains the user-facing name and one-line description of each method, and one display order (Standard, Sortformer, Nemotron 3) that every picker uses. [inferred]
- The Settings diarization section shows the method as a list of three options, each with its description. The "Expected speakers" row and its hint exist only while Standard is picked. [paraphrase]
- The naming dialog's re-run area is two lines: the method picker across the full width, then, on the second line, either the hint (Sortformer, Nemotron 3) or the count (Standard), with the Re-run button at the end of that line. [paraphrase]
- Which wording the dialog uses depends on the job: a two-track recording (the naming data's dual-source flag) talks about "the call audio" and "your microphone"; a single-file job does not. [inferred]
- The pipeline is unchanged: the count still reaches the diarizer, which applies it only in Standard mode and only to the call audio of a two-track recording. [inferred]

## API Contracts

No contract changes. `GET /state` keeps reporting the method by its raw value (`offline` / `sortformer` / `nemotron`), the automation API's naming routes are unchanged, and a re-run still posts the picked method together with a count (the count is simply not chosen by the user in the two overlap-aware modes). [inferred]

## Edge Cases & Constraints

- **Existing installs keep their method.** The stored setting and every recorded job mode stay readable under the old raw values; only display text changes. [inferred]
- **Two-track job where one track's diarization failed or was skipped:** the pipeline then keeps the surviving track's labels without their track prefix, and the naming data does not record which track survived. The dialog's starting count cannot tell call-audio speakers from microphone speakers there, so R6 falls back to counting every speaker. The dialog still labels the count as the call audio's, because a re-run applies it to the call audio. [inferred]
- **Voice enrollment** renders the same view without a recorded method (no method picker): it keeps the count with the single-file wording. [inferred]
- **Cause of the cut-off is unverified.** It was read from the code, not reproduced on screen. The build reproduces it first, by hosting the dialog in a real window at its opening size, before changing the layout. [inferred]
- English UI text only, as everywhere in the app.

## Acceptance Criteria

- **R1:** At the Name Speakers dialog's opening size, every text in the re-run area and the Re-run button's label are shown in full, for each of the three methods and for both two-track and single-file jobs. The Re-run button never wraps or shrinks; a long hint wraps onto further lines instead. Errors: no error surface beyond layout; the dialog may be resized larger by the user but never opens smaller than its content needs. [paraphrase]
- **R2:** Every method picker (Settings and the dialog) lists the methods in the order Standard, Sortformer, Nemotron 3, and no user-visible text calls a method "Offline". The stored setting value and recorded job modes are unchanged, so an install set to the old "Offline" shows Standard picked. Errors: no error surface beyond R2's mapping; an unknown stored value keeps today's fallback. [paraphrase]
- **R3:** In Settings each method shows its one-line description: Standard "Any number of speakers. Groups similar voices."; Sortformer "Handles people talking at the same time. Up to 4 speakers per side."; Nemotron 3 "Handles people talking at the same time. Up to 8 speakers per side." With Sortformer or Nemotron 3 picked, a hint reads "<method> counts the speakers itself. In a recorded call, the call audio and your microphone are two sides, so a call can have up to <8 | 16> speakers." Errors: no error surface beyond text. [paraphrase]
- **R4:** With Sortformer or Nemotron 3 picked, neither Settings nor the dialog shows a speaker count control, and the dialog's Re-run still re-runs with the picked method. Switching the Settings method no longer changes the stored count, so a count chosen for Standard survives a switch to Sortformer and back. Errors: no error surface beyond the stored count being kept as is. [paraphrase]
- **R5:** With Standard picked, the count is labelled for what it affects. Dialog, two-track job: "Speakers in the call audio: N" with the line "Your microphone side is always counted automatically."; dialog, single-file job: "Speakers: N" with no microphone line. Settings: the row "Expected speakers" (Auto or a number) with the hint "Auto finds the number. A fixed number forces exactly that many voices. In a recorded call it counts only the call audio, because your microphone side is always counted automatically. In an imported file it counts everyone." Errors: no error surface beyond text. [paraphrase]
- **R6:** The dialog's count starts at the number of call-audio speakers in the current result plus one when the result carries track-prefixed labels (a two-track job whose both tracks were diarized), and at the number of all speakers plus one otherwise (a single-file job, or a two-track job whose labels carry no track prefix because one track's diarization failed or was skipped). It is at least 2 and at most Standard's cap. Errors: a two-track result with prefixed labels but no call-audio speaker starts at 2; a result with no speakers starts at 2. Examples: three call-audio and two microphone speakers start at 4; three unprefixed speakers start at 4. [inferred]
- **R7:** With Sortformer or Nemotron 3 picked, the dialog's hint reads "<method> counts the speakers itself: up to <4 | 8> in the call audio and <4 | 8> on your microphone." for a two-track job and "<method> counts the speakers itself: up to <4 | 8>." for a single-file job. No text anywhere states a per-meeting cap for a two-track recording. Errors: no error surface beyond text. [paraphrase]

## Boundaries

- No custom or additional diarization models; the three methods stay as they are. [paraphrase]
- No change to how diarization runs, what the count does in Standard mode, or the automation API. [inferred]
- The speaker rows of the naming dialog (play, name field, known-name chips) stay as they are. [paraphrase]
- No new method, no removal of a method, no migration of stored values. [inferred]

## Decision Context

- **D1 · Hide the speaker count while Sortformer or Nemotron 3 is picked, in Settings and in the dialog.** why: both models count speakers themselves and ignore the value, so a visible count does nothing · alternatives: show it greyed out with a hint, rejected because a disabled control still takes room in a row that is already too tight · status: active [owner-ratified 2026-10-16]
- **D2 · Name the methods by what they do (Standard, Sortformer, Nemotron 3, each with a one-line description) and list them in the same order everywhere, Standard first.** why: "Offline" is the speech library's internal name and all three methods run on the Mac · alternatives: name all three by their model (Pyannote, Sortformer, Nemotron 3), rejected as three technical names a user needs background to choose between · status: active [owner-ratified 2026-10-16]
- **D3 · No custom diarization models in this spec.** why: the speech library loads only its own three model types in its own converted format, so there is almost nothing to choose from; a remote server that also returns speaker labels is noted on issue #102 instead · alternatives: a custom model folder setting, rejected because each model needs a manual conversion first · status: active [owner-ratified 2026-10-16]
- **D4 · The accepted mockup is the layout: the dialog's re-run area on two lines (method picker across the full width, then the hint or the count with Re-run at the end), and the Settings method as a list of three options with descriptions.** why: the owner accepted the mockup on 2026-10-20 after the Re-run button was fixed so it no longer wraps · status: active [owner-ratified 2026-10-20]
- **A1 · The stored raw values `offline`, `sortformer`, `nemotron` stay unchanged.** why: they are persisted in settings, recorded jobs and `/state`, and a raw-value pin test already guards them · flip at: a migration is wanted for another reason · test: the existing raw-value pin test still passes · status: active [agent-inferred 2026-10-20]
- **A2 · Changing the Settings method no longer clamps the stored count.** why: with the count hidden in the overlap-aware modes, a clamp there only destroys a value Standard needs · flip at: a reason appears to bound the stored count per method · test: a settings test that a count of 6 survives a switch to Sortformer and back · status: active [agent-assumed 2026-10-20]
- **A3 · The dialog's starting count is the call-audio speakers plus one when labels carry track prefixes, otherwise all speakers plus one, at least 2.** why: today it starts at all speakers plus one, which overshoots the call audio the count applies to; when one track failed the naming data does not say which survived (plan review 2026-10-20), and recording that would need new persisted data for a starting value the user can change in one click · alternatives: persist the surviving track in the naming data, rejected as new stored state for a convenience default · flip at: a one-track fallback starting value is found to mislead in real use · test: naming view tests for a prefixed two-track result, an unprefixed two-track result and a single-file job · status: active [agent-assumed 2026-10-20]
