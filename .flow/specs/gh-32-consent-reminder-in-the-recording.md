# Consent reminder in the recording prompt and Settings

## Conversation Evidence

> user (turn 3): "The not / swiss law - please add it as extra feature in own branch because its very specific and will never push upstream. And show it on the request dialog maybe"
> issue #3 (owner, Hinweis): "Die Rückfrage erinnert auch daran, dass alle Beteiligten mit der Aufnahme einverstanden sein müssen (in der Schweiz strafrechtlich relevant, Art. 179bis ff. StGB). Beim automatischen Start liegt das ganz bei der Person, die aufnimmt — in der Einstellung kurz darauf hinweisen."

## Goal & Context

In Switzerland, recording a conversation without everyone's agreement is a criminal offence (Art. 179bis ff. StGB). Once every detected meeting asks before recording (spec gh-3), the prompt is the natural moment to remind the person recording of that, and Settings is the place to say that a "record without asking" switch hands this responsibility entirely to them. The reminder is specific to Switzerland, so it lives only in this fork and never goes to the original app.

<!-- Source: 50% user / 40% [paraphrase] / 10% [inferred] -->

## Acceptance Criteria

- **R1:** The recording prompt of every app that asks before recording carries a short line that everyone in the meeting must agree to being recorded. No error surface beyond the prompt's existing answers (Record / Ignore / Never for this app). [paraphrase]
- **R2:** While an app's "record without asking" switch is on, Settings shows next to it a short note that, without the prompt, making sure everyone agrees is entirely up to the person recording, naming the Swiss legal basis (Art. 179bis StGB). No error surface beyond the note's visibility. [paraphrase]

## Boundaries

- Fork-only: built on its own branch and never submitted to the original app. [paraphrase]
- No extra dialog or confirmation step beyond the prompt gh-3 introduces; the reminder is text inside existing surfaces. [inferred]

## Decision Context

Split out of gh-3 on 2026-10-05 so that gh-3 (ask before recording, per-app switch) stays suitable for the original app, while this Switzerland-specific wording stays in the fork. [paraphrase]
