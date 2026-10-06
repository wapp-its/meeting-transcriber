# Notices for the remaining automatic stops

## Conversation Evidence

> issue #58 (translated): "Follow-up to #54 (ask with a countdown before stopping automatically). Deliberately taken out of #54 so that part ships first and small; only start once #54 is merged."
> issue #58 (translated): "**4-hour limit:** a warning about 10 minutes before ('Recording ends in 10 minutes, maximum length reached') and a notice when it has taken effect. The limit itself stays fixed."
> issue #58 (translated): "**Manual recording, target app quit:** a notice that the recording ended for that reason (today it ends silently). The stop stays immediate; without the app there is no app audio any more."
> issue #58 (translated): "**Menu bar icon:** a running countdown from #54 can be recognised on the icon, even when notifications are off or invisible (related to #49)."
> issue #58 (translated, acceptance): "Recording approaches 4 h → warning 10 min before, notice at the stop. Manual recording, target app is quit → notice with the reason. Countdown from #54 running → the menu bar icon shows it, independent of notification settings."
> coordinator triage 2026-10-06: "This is the follow-up the gh-54 spec deliberately left out (see that spec's Boundaries and A2): (1) 4-hour cap: a warning about 10 minutes before and a notice when it has ended the recording; the cap itself stays fixed; (2) manual 'App + Microphone' recording whose target app quit: a notice saying the recording ended for that reason (the stop stays immediate); (3) the menu bar icon shows a running gh-54 countdown, independent of notification settings."
> coordinator triage 2026-10-06: "Depends on spec gh-54-ask-before-auto-stopping-a-meeting (issue #54), being built by another session now, not merged. Plan against its design (countdown state, notification category, the stop-reason log lines of its R7)."
> coordinator triage 2026-10-06: "Issue #49 (pending 'Record … meeting?' prompt shown on the icon) is planned in parallel and also adds an icon state; plan the countdown indication so it fits beside that (BadgeKind/MenuBarIcon), and say which should land first."

## Goal & Context

Three automatic stops still happen without the person recording being told, or with no way to see them coming. Every recording, detected or started by hand, ends at a fixed maximum length of 4 hours (`WatchLoop.maxDuration`, 14 400 s), and today that stop only writes a log line, in both the detected-meeting wait and the manual-recording monitor: a long workshop is cut off mid-sentence without warning. A manual recording of an app ends at once when that app quits, again only with a log line. And the countdown that spec gh-54 adds before ending a detected meeting is announced only by a notification; with notifications denied, switched to "None" or hidden by a Focus, nothing shows that the recording is about to end. [paraphrase]

This spec adds a warning before the 4-hour stop, a notice after it, a notice when a manual recording ends because its app quit, and a mark on the menu bar icon while a gh-54 countdown runs. The stops themselves keep their current rules. [paraphrase]

It builds on spec gh-54 (issue #54), which is not merged yet: gh-54 introduces the countdown, the meeting-end notification category and one diagnostic log line per automatic stop (its R7). This spec relies on those and changes none of them. [inferred]

<!-- Source: 0% user / 70% [paraphrase] / 30% [inferred] -->

## Architecture & Data Models

- **Cap warning, one pure decision.** A small pure type decides, from the time a recording has run, its maximum length, a warning lead (10 minutes in the app) and whether this recording was already warned, whether to warn on this poll. The two existing poll loops call it: gh-54's meeting-end wait for detected meetings (`waitForMeetingEnd`) and `monitorManualRecording` for manual app and microphone-only recordings. Each loop keeps a local "already warned" flag, so a recording is warned at most once. It sits beside gh-54's rewritten `WatchLoopEndPolicy`, not inside it, so this spec does not reshape gh-54's state machine. [inferred]
- **Notice texts, one pure builder.** The texts of the warning, the cap notice and the app-exit notice come from one pure builder (title and body as values), so tests pin the wording without a notification centre. Remaining minutes and the maximum length are formatted from the actual values, never hard-coded. [inferred]
- **Posting.** All three go through the existing `AppNotifying.notify(title:body:urgency:)` seam; no new notification category, no actions. The warning is `.timeSensitive`, the two "recording ended" notices `.standard` (`NotificationUrgency`). [inferred]
- **Where each notice is posted.** The cap notice is posted where the stop reason is known to be the maximum length: for detected meetings next to gh-54's R7 `max_duration` log line in the meeting-end wait, for manual recordings in `monitorManualRecording` after `stopManualRecording()`. The app-exit notice is posted in `monitorManualRecording` after `stopManualRecording()` on the `.stopPidExited` arm. A stop the person makes (menu, automation API, Stop Watching) and a meeting end decided by gh-54 post none of them. [inferred]
- **Countdown state on the loop.** `WatchLoop` exposes, as observable read-only state, the deadline of a running gh-54 countdown (`meetingEndDeadline: Date?`, nil when none runs), written only by the meeting-end wait the way `pendingConsentApp` is written only by the consent extension. It is set on the poll that opens gh-54's question and cleared on every way out of it, including thrown errors and cancellation. If gh-54 merged an equivalent observable property, that one is used instead of adding a second. [inferred]
- **Countdown mark on the icon.** `MenuBarIcon.image(...)` gains one more overlay flag next to `watchingOverlay` and the red overlays. With it set, the whole icon is drawn faded on the second half of the 6-frame animation cycle (frames 3 to 5, 1.2 s of every 2.4 s), so the recording waveform pulses. It is an overlay on the `.recording` badge, not a new `BadgeKind` case, so the `badge` value the `/v1` automation API reports (`WatchStatusDTO`, `RecordStatusDTO`) keeps saying `recording` during a countdown. `AppState` hoists the flag into one named property for the menu-bar body's type-check budget (the `hasPermissionProblem` pattern), and `MeetingTranscriberApp.menuBarLabel` passes it to `AnimatedMenuBarIcon`. [inferred]
- **Fit beside issue #49.** #49 marks a pending "Record … meeting?" prompt, which is usually open while the app watches without recording (it can stay parked while another app's meeting records); this mark appears only while a detected meeting records and its signal is gone. Both read as "the app waits for your answer", and this one never competes for the badge, since it does not touch `BadgeKind.compute`. Both specs touch the parameter list of `MenuBarIcon.image`, `AnimatedMenuBarIcon` and `menuBarLabel`; whichever lands second adds its flag next to the other's. [inferred]

## Edge Cases & Constraints

- A recording that ends before the warning point (meeting over, stopped by hand, app quit) gets no warning and no cap notice. [inferred]
- A maximum length at or below the warning lead (only possible in tests) produces no warning; the cap still stops the recording. [inferred]
- A recording that reaches the warning point with less than 10 minutes left (the Mac slept through the warning point, or a poll landed late) is warned once with the minutes actually left, rounded up, at least 1. A poll that is already past the cap stops the recording with the cap notice and no warning. [inferred]
- The cap reached while a gh-54 countdown runs ends the recording exactly as gh-54 decides (cut back, question withdrawn); this spec adds only the cap notice. [paraphrase]
- A gh-54 countdown and the cap warning can both be open at once; neither changes the other. [inferred]
- Microphone-only recordings have no app that can quit; they get the warning and the cap notice, never the app-exit notice. [inferred]
- Record-only mode changes nothing here: the notices are about the recording, not about processing. [inferred]
- Notifications denied, switched to "None" or hidden by a Focus: the warning and notices are dropped or hidden as any notification is today (the existing `notification_dropped` / `notification_settings` lines record it); the stops are unaffected, and the countdown mark (R4) does not depend on notifications at all. [paraphrase]
- No meeting title, app window title, participant or transcript content in the new diagnostic line; notification texts may carry the meeting title, as the existing "Meeting Detected" and "Manual Recording" notifications already do. [inferred]
- File-length cap: `swiftlint --strict` makes the 600-line `file_length` warning an error, and `WatchLoop`, `AppState` and the shared test helpers sit at it, so new types and tests go in new files. [inferred]

### Verification

- Pure tests for the warning decision (before the window, inside it, already warned, past the cap, a cap at or below the lead) and for the three notice texts at the production values (14 400 s cap, 600 s lead), including singular "1 minute". [inferred]
- `WatchLoop` tests on the injected `TestClock` with the `RecordingNotifier` spy: a manual app recording, a microphone-only recording and a detected meeting each get exactly one warning and, at the cap, one cap notice; a manual recording whose app exits gets the app-exit notice and no cap notice; a recording stopped by hand or ended by gh-54's meeting-end path gets none of them. The warning lead is injectable on `WatchLoop`, so these run with a short cap instead of 4 hours of virtual polls. [inferred]
- A `WatchLoop` test drives a detected meeting into a gh-54 countdown and checks that `meetingEndDeadline` is set while it runs and nil again after each way out (signal back, "Keep recording", expiry, Stop Watching). An `AppState` test checks that the hoisted flag follows it. [inferred]
- A pixel test renders the icon with the countdown overlay: frames 0 to 2 match the icon without it, frames 3 to 5 carry clearly less alpha, and the image stays a template when no red overlay is set. [inferred]
- Look and feel of the pulsing icon in a light and a dark menu bar, and a real manual recording of an app that is then quit, are checked by the owner after merge. [inferred]

## Acceptance Criteria

- **R1:** When any recording (detected meeting, manual app recording or microphone-only recording) has 10 minutes left before its 4-hour maximum, the app posts one time-sensitive notification saying the recording ends in 10 minutes because the maximum length is reached, and writes one diagnostic line `recording_cap_warning trigger=<auto|manual> remaining_s=<seconds>` with no title or content. A recording is warned at most once; a recording that ends earlier is not warned. Errors: a notification that cannot be posted is dropped and logged as any notification is today; the recording and its cap are unaffected. [paraphrase]
- **R2:** When a recording reaches its 4-hour maximum, it ends exactly as today (and as gh-54 decides when its countdown is open), and the app posts a notification that the recording ended because it reached the maximum length of 4 hours. Recordings ended any other way get no such notice. Errors: a notification that cannot be posted changes nothing about the stop or the processing. [paraphrase]
- **R3:** When the app a manual app recording targets quits, the recording ends at once and is processed as today, and the app posts a notification naming that app and saying the recording ended because it quit. A manual recording stopped by the person, a microphone-only recording and a recording ended by the cap get no such notice. Errors: a notification that cannot be posted changes nothing about the stop or the processing. [paraphrase]
- **R4:** While a gh-54 countdown runs, the menu bar icon pulses (the recording waveform fades on and off), whatever the notification permission, alert style or Focus; it stops pulsing as soon as the countdown ends by any path (signal back, "Keep recording", "Stop now", expiry, maximum length, Stop Watching). Nothing else makes the icon pulse, and the `/v1` `badge` value stays `recording` during the countdown. Errors: no error surface; the mark is derived from the loop's state alone. [paraphrase]

## Early proof point

Task gh-58-notices-for-the-remaining-automatic.1 validates the core approach (a pure decision called from both poll loops of gh-54's merged code, posting through the existing notifier seam). If it fails, re-evaluate where gh-54 put its stop decision before continuing with gh-58-notices-for-the-remaining-automatic.2.

## Dependencies

- Spec gh-54-ask-before-auto-stopping-a-meeting (issue #54) must be merged first: this spec uses its countdown, its meeting-end decision and its R7 stop-reason log lines and changes none of them. [inferred]
- Issue #49 (pending "Record … meeting?" prompt on the icon) touches the same icon parameters; landing it first is recommended (A5). [inferred]

## Boundaries

- The 4-hour maximum stays fixed and gets no setting; the 10-minute warning lead is fixed too. [paraphrase]
- The app-exit stop stays immediate; only the notice is new. Detected meetings whose app quits are gh-54's countdown and get no extra notice here. [paraphrase]
- gh-54's countdown, notification, cut-back and log lines are used as they are, not changed. [inferred]
- Follow-up, not planned: answering the countdown from the menu-bar dropdown ("Keep recording" / "Stop now"), for people whose notifications are off; today the mark shows the countdown but the answer still needs the notification. [inferred]
- Follow-up, not planned: showing the remaining time (text such as "1:42") in the menu bar; the mark shows that a countdown runs, not how long it has left. [inferred]
- Follow-up, not planned: withdrawing a cap warning from Notification Center when the recording ends before the cap. [inferred]
- Follow-up, not planned: exposing the countdown on `/state` or `/v1` for automation clients. [inferred]

## Quick commands

```bash
mkdir -p /private/tmp/mt-gh58/home && cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh58/home swift test --parallel --filter 'RecordingStopNoticesTests|WatchLoopStopNoticeTests|MenuBarIconCountdownTests|WatchLoopMeetingEndDeadlineTests' > /private/tmp/mt-gh58/tests.log 2>&1; echo "exit=$?"
```

## Decision Context

- **D1 · The 4-hour maximum stays fixed; only a warning about 10 minutes before and a notice after are added.** why: issue #58 "The limit itself stays fixed", repeated by the coordinator triage · status: active [owner-stated 2026-10-06]
- **D2 · A manual recording whose app quits still stops at once; only a notice is added.** why: issue #58 "The stop stays immediate; without the app there is no app audio any more" · status: active [owner-stated 2026-10-06]
- **D3 · A running gh-54 countdown is shown on the menu bar icon, independent of notification settings.** why: issue #58 acceptance "Countdown from #54 running → the menu bar icon shows it, independent of notification settings" · status: active [owner-stated 2026-10-06]
- **A1 · The countdown mark is a pulse: the whole icon drawn faded on frames 3 to 5 of the 6-frame cycle.** flip at: the owner's look-and-feel check prefers another mark · test: MenuBarIcon countdown pixel test · alternatives: a small hourglass or shrinking pie in a corner, rejected because at 18 pt beside the watching dot and the red badges it is hard to notice, and noticing is the point · status: active [agent-assumed 2026-10-06]
- **A2 · The mark is an overlay flag on the recording badge, not a new BadgeKind case.** why: docs/automation-api.md lists the `badge` values under the /v1 stability contract · flip at: an automation client needs to see the countdown in `badge` · test: WatchStatusDTO badge stays `recording` during a countdown; BadgeKind.compute unchanged · status: active [agent-inferred 2026-10-06]
- **A3 · The warning is time sensitive, the two "recording ended" notices are standard.** why: NotificationUrgency reserves time sensitive for something the person can still act on; the warning lets them split a long recording at a convenient moment, the ended notices report the past like PreviousExitNotice · flip at: the owner wants the ended notices to break through Focus too · test: RecordingNotifier urgency assertions · status: active [agent-assumed 2026-10-06]
- **A4 · The warning lead is a fixed 10 minutes with no setting, and no warning is given when the maximum is not longer than the lead.** flip at: the owner asks for a setting · test: Settings gains no control; the pure warning test covers a cap at or below the lead · status: active [agent-assumed 2026-10-06]
- **A5 · gh-49 should land before this spec.** why: gh-49 has no unmerged dependency while this spec waits for gh-54, and the shared icon-parameter conflict is small either way · flip at: gh-54 merges before gh-49 is built · test: none, an ordering note for the coordinator · status: active [agent-inferred 2026-10-06]
## Requirement coverage

| Req | Description | Task(s) | Gap justification |
| --- | --- | --- | --- |
| R1 | When any recording (detected meeting, manual app recording or microphone-only recording) has 10 minutes left before its 4-hour maximum, the app posts one time-sensitive notification saying the recording ends in 10 minutes because the maximum length is reached, and writes one diagnostic line `recording_cap_warning trigger=<auto\|manual> remaining_s=<seconds>` with no title or content. A recording is warned at most once; a recording that ends earlier is not warned. Errors: a notification that cannot be posted is dropped and logged as any notification is today; the recording and its cap are unaffected. | gh-58-notices-for-the-remaining-automatic.1 | — |
| R2 | When a recording reaches its 4-hour maximum, it ends exactly as today (and as gh-54 decides when its countdown is open), and the app posts a notification that the recording ended because it reached the maximum length of 4 hours. Recordings ended any other way get no such notice. Errors: a notification that cannot be posted changes nothing about the stop or the processing. | gh-58-notices-for-the-remaining-automatic.1 | — |
| R3 | When the app a manual app recording targets quits, the recording ends at once and is processed as today, and the app posts a notification naming that app and saying the recording ended because it quit. A manual recording stopped by the person, a microphone-only recording and a recording ended by the cap get no such notice. Errors: a notification that cannot be posted changes nothing about the stop or the processing. | gh-58-notices-for-the-remaining-automatic.1 | — |
| R4 | While a gh-54 countdown runs, the menu bar icon pulses (the recording waveform fades on and off), whatever the notification permission, alert style or Focus; it stops pulsing as soon as the countdown ends by any path (signal back, "Keep recording", "Stop now", expiry, maximum length, Stop Watching). Nothing else makes the icon pulse, and the `/v1` `badge` value stays `recording` during the countdown. Errors: no error surface; the mark is derived from the loop's state alone. | gh-58-notices-for-the-remaining-automatic.2 | — |

