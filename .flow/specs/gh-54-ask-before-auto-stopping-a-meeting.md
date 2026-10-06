# Ask before auto-stopping a meeting recording

## Conversation Evidence

> user (turn 1): "Can you check the current auto stop feature of a meeting recording? So it seems like it stops auto recording after a while. It should ask for m maybe before it stops the recording, not automatically. Because otherwise maybe it stops recording and then parts get lost."
> user (turn 2, selected): "B — 2-min countdown (Recommended)"
> issue #54 (owner decision comment, 2026-10-06): "Entscheidung (Owner, 2026-10-06): **B** – Rückfrage mit 2-Minuten-Countdown, ohne Antwort endet die Aufnahme. A und C verworfen (A: Raum wird nach übersehener Mitteilung weiter aufgenommen; C: bleibt still, Aussetzer über 2 min teilen das Meeting weiterhin)."

## Goal & Context

Today an automatically detected meeting is stopped silently once the app has seen no sign of the call for the end-grace period (15 s by default): no "call in progress" signal from the meeting app, no microphone held by it, no meeting window. When that signal drops while the call is still going (hold, device switch, a hand-off to the phone), the recording is finished and processed, and a call that comes back becomes a second recording with a gap in between; if it never comes back, the rest of the meeting is lost. The person recording wants to be asked before the app stops, so a wrong stop can be prevented and no part of a meeting is lost. [paraphrase]

The diagnostic logs of the last nine days show eight Teams recordings that ended on their own, each about 15 s after Teams stopped all audio output, which fits real hang-ups; whether any of them cut a live call cannot be told from the logs, partly because the stop itself is not logged. [paraphrase]

Recording people after a meeting has ended is not free in Switzerland (everyone recorded must agree, see the fork's consent reminder), so the fix must not leave the room being recorded because a notification went unseen. [paraphrase]

<!-- Source: 15% user / 60% [paraphrase] / 25% [inferred] -->

## Architecture & Data Models

- The meeting-end decision gains a third state between "keep polling" and "stop": an end that is pending, with the time the signal was lost and a deadline. It goes back to polling when the signal returns, resolves to a stop on the deadline or on "Stop now", and resolves to a kept episode on "Keep recording". [inferred]
- The person's answer arrives out of band, the way the "Record … meeting?" start prompt's answer already does, so detection keeps polling while the question is open. [paraphrase]
- The end notification is its own kind of notification with its own two actions; it does not reuse the start prompt's answers (Record / Ignore / Never), because a stop, a dismissal and an expiry must stay distinguishable. [paraphrase]
- The cut-back of R2 applies to every saved track of the recording at the same point on the recording's timeline, after the recorder stops and before the job is queued. [inferred]

## Edge Cases & Constraints

- The signal flapping (lost, back, lost again) inside one countdown: a return cancels the countdown (R3); the next loss starts a fresh end-grace period. [inferred]
- A click on a notification that belongs to an episode that has already ended (signal returned, recording already stopped) changes nothing. [inferred]
- Notification permission denied, alert style "None" or Focus hiding the banner: the countdown still runs (R5). [paraphrase]
- The 4-hour cap reached while a countdown is pending ends the recording as in R2 (cut back, notification withdrawn); reached after "Keep recording", it ends the recording uncut as today. [inferred]
- Record-only mode: the saved files are cut the same way, and the sidecar's stop time is the cut point, so the sidecar never claims audio the files no longer hold. [inferred]
- A failed cut leaves every original track in place and untouched; a track is never left half-cut or cut at a different point from the others. [inferred]

### Verification

- The countdown length and the clock are injectable, so tests drive countdown expiry, "Stop now", "Keep recording", a returning signal, stale answers, notifications that cannot be shown, cancellation by Stop Watching and the cap during a countdown deterministically, without waiting two real minutes. [inferred]
- WAV-fixture tests check the cut: every saved track (app, microphone, mix, and the record-only output) ends at the same timeline point, and a forced cut failure leaves the originals intact and processed. [inferred]
- Existing end-to-end tests that end a recording through a short maximum duration or the end grace are adjusted so the end condition they meant to exercise still fires, with a short injected countdown where the meeting-end path is under test. [inferred]
- A live check in the shipped app (meeting simulator or a real call ended mid-run) confirms the notification appears, "Keep recording" and a returning signal keep one recording, and an unanswered countdown yields a recording no longer than today's. [inferred]

## Acceptance Criteria

- **R1:** When an automatically detected meeting has shown no detection signal for the end-grace period, the recording keeps running and the app posts a notification saying the meeting seems to have ended and the recording will end in 2 minutes, with the actions "Keep recording" and "Stop now". Errors: a notification that cannot be posted or is not shown is handled by R5. [paraphrase]
- **R2:** When the 2 minutes pass without an answer, or on "Stop now", the recording ends and is processed as today, and the saved audio ends where today's automatic stop would have ended it: the moment the signal was lost plus the end-grace period. Audio after that point is neither kept nor transcribed. Errors: if cutting the audio fails, the recording is processed uncut and the failure is logged; the recording is never discarded. [paraphrase]
- **R3:** When the detection signal returns before the countdown ends, the pending stop is cancelled, the notification is withdrawn, and the recording continues as one recording with no gap; a later loss of the signal starts a fresh end-grace period and, after it, a fresh notification. Errors: an answer to the withdrawn notification changes nothing. [paraphrase]
- **R4:** "Keep recording" keeps the whole recording uncut and posts no further end notification while the signal stays absent; the recording then runs until the person stops it or the 4-hour cap ends it. If the signal returns, R1–R3 apply again to the next loss. Errors: an answer arriving after the recording has already ended changes nothing. [paraphrase]
- **R5:** When notifications are denied, switched off or not shown, the same countdown runs and ends the recording as in R2; the app never keeps recording because a notification went unseen. Errors: no error surface beyond R2. [paraphrase]
- **R6:** Stopping meeting watching while a countdown is pending ends the recording as in R2 and withdraws the notification. Starting a manual recording stays refused while any recording runs, a pending countdown included, exactly as today. Errors: no error surface beyond R2. [inferred]
- **R7:** Every automatic stop writes its reason to the diagnostic log the app keeps on disk: countdown expired, "Stop now", maximum duration reached, or (manual recordings) monitored app exited, with how long the signal had been absent where that applies. These lines carry no meeting title, participant name or transcript content. Errors: no error surface beyond the log write itself. [paraphrase]

## Boundaries

- Only automatically detected meetings get the notification; manual recordings keep their current stop rules (target app exits, 4-hour cap), apart from R7's log line. [paraphrase]
- The 4-hour cap stays a hard stop. A warning before it, a notice when a manual recording stops because its app quit, and a menu-bar indication of a pending countdown belong to a follow-up spec that depends on this one. [paraphrase]
- The end-grace setting keeps its meaning (time without a signal before the notification appears); the 2-minute countdown is fixed and gets no setting. [inferred]
- R2 governs the saved recording and everything made from it (transcript, protocol, record-only files). Live captions, an opt-in on-screen display that is never saved, keep running during the countdown as during any part of a recording. [inferred]

## Decision Context

- **D1 · Ask with a 2-minute countdown; no answer ends the recording (option B).** why: a wrong end happens while the person is in the call at the screen and sees the banner, and a real end needs no click; the room is never recorded unnoticed. alternatives: A (record until answered) rejected because a missed banner keeps recording people who did not agree; C (only raise the end-grace setting) rejected because it stays silent and drops longer than 2 minutes still split the meeting · status: active [owner-ratified 2026-10-06]
- **A1 · An unanswered countdown or "Stop now" cuts the recording back to today's end point (signal lost plus end grace).** flip at: the owner wants the extra minutes kept · test: a real meeting end produces audio of the same length as today, and nothing recorded during the countdown reaches the transcript · status: superseded by D2 [agent-assumed 2026-10-06]
- **A2 · The 4-hour cap stays absolute; its warning, the app-exit notice and a menu-bar countdown go to a follow-up spec.** flip at: the owner asks to fold them in · test: this spec's diff leaves the cap's stop behaviour unchanged apart from R7's log line · status: active [agent-inferred 2026-10-06] (a Codex second opinion on 2026-10-06 also kept the cap absolute and the app-exit stop immediate)
- **A3 · The countdown is a fixed 2 minutes, with no setting.** flip at: the owner asks for a setting · test: Settings gains no new control · status: active [agent-assumed 2026-10-06]
- **D2 · An unanswered countdown or "Stop now" cuts the recording back to today's end point (signal lost plus end grace), so the minutes recorded during the countdown are neither kept nor transcribed.** why: a real meeting end then gives exactly today's transcript, and people in the room after the meeting, who never agreed to be recorded, stay out of it. alternatives: keep the countdown minutes, rejected because every meeting would carry about 2 minutes of room audio into the transcript and summary · status: active [owner-ratified 2026-10-06]
