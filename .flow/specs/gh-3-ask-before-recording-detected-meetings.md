# Ask before recording detected meetings

## Conversation Evidence

> user (turn 1): "Oh and its now automatically recording every meeting automatically. This should be an extra setting, but better default would be if it asks first if it should record, isnt it?"
> user (turn 2, selected): "A: Ask first, per-app switch (Recommended)"
> issue #3 (owner, Wunsch): "Option „Erkannte Meetings ohne Rückfrage aufnehmen", am besten je App einstellbar (z. B. Teams: immer, Browser: fragen) — als Gegenstück zur bestehenden Sperrliste consentDeniedApps."
> issue #3 (owner, Hinweis): "Die Rückfrage erinnert auch daran, dass alle Beteiligten mit der Aufnahme einverstanden sein müssen (in der Schweiz strafrechtlich relevant, Art. 179bis ff. StGB). Beim automatischen Start liegt das ganz bei der Person, die aufnimmt — in der Einstellung kurz darauf hinweisen."
> user (turn 3): "The not / swiss law - please add it as extra feature in own branch because its very specific and will never push upstream. And show it on the request dialog maybe"
> issue #3 (owner, Abnahme): "Option für Teams eingeschaltet → Teams-Meeting beginnt → Aufnahme startet ohne Mitteilung. Für andere Apps unverändert mit Rückfrage."

## Goal & Context

While "Watch for meetings" runs, the app today records Teams, Zoom and Webex calls (watched by default) and FaceTime, WhatsApp, WeChat and Tencent Meeting calls (opt-in) the moment it detects them, without asking. Only browser meetings ask first, through a notification with Record / Ignore / Never for this app. This is the original app's behaviour, not a fork feature. The owner wants the opposite default: every detected meeting asks first, and recording without asking becomes an explicit per-app choice. Asking first also gives the person recording a moment to make sure everyone in the meeting agrees; a written reminder of that legal requirement is a separate, fork-only feature (issue #32).

<!-- Source: 60% user / 30% [paraphrase] / 10% [inferred] -->

## Architecture & Data Models

- **Who asks.** Whether a detected meeting needs a prompt is decided per app from settings, no longer fixed in the meeting pattern: a watched app asks unless its "record without asking" switch is on. Browser meetings always ask. [paraphrase]
- **One consent path for every app.** Native and mic-input detections use the consent flow browser meetings already use: the prompt is awaited off the poll loop, the per-app cooldowns after Ignore and after no answer, the "Never for this app" deny list, and at most one open prompt at a time. Mic-input detections join the same gate. [inferred]
- **Setting.** One persisted per-app list of apps whose meetings record without asking, empty by default. A name that matches no watched app is ignored. It is the counterpart of the existing deny list (`consentDeniedApps`). [paraphrase]
- **Prompt text.** The prompt names the concrete app ("Record <app> meeting?"), not "browser". [inferred]

## Edge Cases & Constraints

- A meeting detected while another prompt is open waits; it is asked about once the open prompt is answered or expires. [inferred]
- No answer within the prompt timeout means no recording, as for browser meetings today. The start of a meeting is lost while a prompt waits; that is the accepted cost of asking first. [inferred]
- Record-only mode asks the same way; only the destination of the recording differs. [inferred]
- An app on the deny list is never asked about and never recorded, whatever its "record without asking" switch says. [inferred]

## Acceptance Criteria

- **R1:** With watching on, a meeting detected in any watched app (Teams, Zoom, Webex, FaceTime, WhatsApp, WeChat, Tencent Meeting, browser meetings) starts recording only after the user answers its prompt with Record, unless that app's "record without asking" switch is on. Errors: Ignore, Never for this app, or no answer within the prompt timeout → no recording; the cooldown and deny-list rules that apply to browser meetings today apply to every app. [paraphrase]
- **R2:** Settings offers a "record without asking" switch for each native and mic-input app (Teams, Zoom, Webex, FaceTime, WhatsApp, WeChat, Tencent Meeting), off by default. With the switch on for Teams, a Teams meeting starts recording without a notification, and other apps still ask. Errors: the switch has no effect while that app is not watched, or while the app is on the deny list. [paraphrase]
- **R3:** Browser meetings always ask; they get no "record without asking" switch, because their detection signal also fires on pages that are not meetings. [inferred]
- **R5:** The prompt names the detected app and offers Record, Ignore and Never for this app, for every app that asks. No error surface beyond R1's answer handling. [inferred]
- **R6:** The Settings warning that notifications cannot be seen (denied, banners off, alerts silenced, Time Sensitive off) appears whenever at least one watched app asks first, not only when browser meetings are watched, because a prompt nobody sees means nothing is recorded. Errors: no warning when every watched app records without asking. [inferred]
- **R7:** Starting a recording by hand (app picker, menu, automation API) never asks, as today. No error surface beyond the existing manual-start behaviour. [inferred]

## Boundaries

- Choosing a protocol template or meeting notes when a recording starts (issue #2) is not part of this. [paraphrase]
- How meetings are detected does not change; only what happens after a detection. [inferred]
- No provisional recording before the answer: nothing is captured until the user says Record. [inferred]
- No legal or consent wording in the prompt or in Settings: the Swiss-law consent reminder is its own fork-only feature (issue #32), built on top of this one. [paraphrase]

## Decision Context

### Motivation

The owner found the app recording every meeting automatically and wants it to ask first by default, with recording without asking as a separate, per-app setting (option A, chosen 2026-10-05). The consent reminder issue #3 asked for moved to its own fork-only feature (issue #32) on 2026-10-05, because it is specific to Switzerland and will never go to the original app, while this spec may. [paraphrase]

Rejected: keeping auto-recording as the default with a per-app "ask first" switch (B), and one global "ask before recording" switch (C), both offered on 2026-10-05. Recording provisionally and discarding on a decline was not offered because it captures audio before anyone agreed, which is what the prompt exists to prevent. [inferred]
