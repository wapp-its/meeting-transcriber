# Name Teams recordings after the meeting window

## Conversation Evidence

The fork is public, so the owner's turns are paraphrased, not quoted, and the meeting names in this spec are made up.

> owner (paraphrased, 2026-11-16): in All Recordings, Teams recordings get different kinds of titles. Most show the meeting window's title in the form "<meeting name> | <organisation> | <account>", which is the most useful one. One showed the name of another Teams window. The newest shows "Meeting compact view | Meeting in <channel>". A recording should get the title that best describes the meeting, every time.

## Goal & Context

<!-- Source: 30% [paraphrase] / 70% [inferred] -->

A detected Teams meeting is named once, at detection, after one Teams window. The pick (`MeetingTitleMatcher.selectWindowTitle`) skips Teams' tab titles (Calendar, Chat, Teams and the others on the idle list), prefers a title that matches the Teams meeting pattern (`<something> | Microsoft Teams`), and otherwise takes the first remaining window in the order the system window list gives. Teams ends most window titles with " | Microsoft Teams": its main window reads "<tab> | <organisation> | <account> | Microsoft Teams", the shape the original project's idle-tab fix was written against. So the preference most likely does not single out the meeting window, and whichever non-tab Teams window comes first names the recording. That is how one recording got another window's name and the newest got Teams' compact call window ("Meeting compact view | Meeting in <channel>"). The title is never read again, so a call detected while another window was in front keeps that name in All Recordings, in the file names of its transcript, notes and audio, in the notices and in the template rule that picks its notes template.

After this spec, the Teams window that looks most like the meeting window names the recording, and a better window that appears while the call runs replaces a weaker title. The "<meeting> | <organisation> | <account>" form stays as Teams writes it (D1). Without the Screen Recording grant the window list carries no titles and the recording keeps the placeholder "Microsoft Teams Call", as today.

Upstream: the original project's open pull request pasrom/meeting-transcriber#979 passes the meeting title to the notes prompt and keeps only the part before the first " | ". It does not change which window is picked, so it does not overlap this fix. With the compact prefix removed (R2), that part is the meeting's name and not "Meeting compact view".

## Architecture & Data Models

- **One pure ranking for Teams window titles.** Input: the window list in its order. Output: the chosen title and its rank, or nil. Ranks, best first: [inferred]
  1. *Meeting window:* three or more " | "-separated parts once a trailing " | Microsoft Teams" is removed ("Sprint Review | Contoso | user@contoso.com | Microsoft Teams").
  2. *Compact call window:* starts with "Meeting compact view | "; what follows is the title ("Meeting compact view | Meeting in General").
  3. *Other Teams window with the app's suffix:* any other title ending in " | Microsoft Teams" ("Jane Doe | Microsoft Teams", the 1:1 call shape the existing tests know).
  4. *Any other window:* any other title ("Some Popup").
  Idle tab titles, empty titles and the app's own name never count, as today. Within a rank, the first window in list order wins.
- **The running recording owns its title, not the detector.** The detection snapshot (`DetectedMeeting`) stays as it is. The watch loop keeps the recording's current title and its rank, starting from the detection title, and every consumer that reads the detected title during or after the recording reads that one instead. [inferred]
- **The refresh rides the meeting-end wait's poll:** a detector call answers the best Teams title for the meeting right now (nil when it has none), and the wait compares its rank with the one held. No new timer and no new thread. [inferred]
- **Tests at the cheapest layer:** the ranking with window lists in and the title out (pure logic), and one watch-loop test where a fake detector offers a better window during the recording and the enqueued job carries it. [inferred]

## API Contracts

- While the recording runs, the menu's meeting line and its "Recording: <title>" status show the held title. No new `/state` or `/v1` field and no new setting; a finished job's `meetingTitle` in both is the title the recording held at its stop. [inferred]

## Edge Cases & Constraints

- **No Screen Recording grant:** the list carries no titles, the pick is nil and the recording keeps "Microsoft Teams Call" for its whole length. [inferred]
- **A compact-view title with nothing after the prefix** is skipped. [inferred]
- **A held title is never replaced by an equal or weaker rank**, so moving between two windows of the same rank does not flip it. [inferred]
- **After the call signal is lost** (the end grace, the "meeting seems to have ended" question), the title no longer changes: windows shown after a call say nothing about it. [inferred]
- **Consent:** the prompt is asked with the detection title, and recording starts later, so the first poll of the wait may already improve it. A template picked in "Record with Options…" stays as picked; without the options window, the template rule runs on the final title when the job enters the queue. [inferred]
- **Record Again, an approved prompt and the next call after a split** each start from their own detection title. [inferred]
- **Teams in another interface language:** the compact prefix and the idle list are English, so a translated compact window ranks 3 or 4. [inferred]
- **Privacy:** titles are user text. The new log lines carry the rank and the part count only, never the title, and the title stays a private value wherever it is logged today. [inferred]
- **Cost:** one window list read per poll of a running Teams recording; detection already reads the list on every poll while watching. [inferred]

## Acceptance Criteria

- **R1:** For a Teams window list, the chosen title comes from the best-ranked window of the four ranks in Architecture, and from the first window in list order within a rank. Errors: idle tab titles, empty titles and the app's own name never count; a compact-view title with nothing after the prefix is skipped; no usable window gives nil, and the recording is named "Microsoft Teams Call". Tests: window lists in, title out, one per rank and per tie, plus the three reported cases with made-up names (a meeting window behind another Teams window, the compact window alone, the compact window in front of the meeting window). [inferred]
- **R2:** The recording's title text is the chosen title with a trailing " | Microsoft Teams" removed (as today) and, for the compact window, with its prefix removed; the organisation and account parts stay. "Sprint Review | Contoso | user@contoso.com | Microsoft Teams" becomes "Sprint Review | Contoso | user@contoso.com", and "Meeting compact view | Meeting in General | Microsoft Teams" becomes "Meeting in General". Errors: no error surface beyond R1. [inferred]
- **R3:** While a detected Teams recording runs and its call signal is present, each poll of the meeting-end wait reads the Teams windows again; a title of a better rank than the one held replaces it, and an equal or weaker one never does. Errors: a poll with no usable window keeps the held title; polls after the signal is lost change nothing; a recording detected with the placeholder takes the first usable title. Test: one watch-loop test where the detection title is rank 4, a later poll offers a meeting window and the enqueued job carries the meeting window's title, and a rank-3 window offered after that does not replace it. [inferred]
- **R4:** The title a recording holds when it stops is the one its job gets (All Recordings, the file names, the template rule at queue admission, the naming dialog and the notices) and the one a record-only sidecar gets; while it runs, the menu's meeting line and its "Recording: <title>" status show the held title. Errors: a template chosen by hand stays as chosen; a notice already posted is not posted again. [inferred]
- **R5:** Zoom, Webex, browser meetings and the apps detected by microphone keep today's title pick and get no refresh; the existing title tests pass unchanged. Errors: no error surface beyond R1. [inferred]
- **R6:** One diagnostics line at detection and one at each title change name the rank and the number of title parts, never the title text. Errors: no error surface beyond R1. [inferred]
- **R7:** `docs/architecture/detection.md` says where a meeting's title comes from, the Teams ranks and why, the refresh, and the Screen Recording dependency. Errors: no error surface. [inferred]

## Boundaries

- No change to recordings that already exist: their titles and file names stay (A4). [inferred]
- No new setting, and no way to rename a recording by hand. [inferred]
- No title from the Accessibility API or from the calendar. [inferred]
- No change to how meetings are detected or when a recording ends. [inferred]

## Decision Context

- **D1 · A detected meeting gets the title that best describes it, every time; the meeting window's "<meeting> | <organisation> | <account>" form is the most useful one.** why: the owner's report of 2026-11-16 (paraphrased), issue #258 · status: active [owner-stated 2026-11-16]
- **A1 · Teams windows are ranked: the meeting window shape, then the compact call window without its prefix, then other windows with the Teams suffix, then any other window; ties go to list order.** flip at: the owner's answer, or an R6 log line showing a meeting window in another shape · test: R1's ranking tests · alternatives: B rank only by the Teams suffix as today and fix the order alone · status: active [agent-assumed 2026-11-16]
- **A2 · The title follows a better-ranked window while the call runs, never a weaker one.** flip at: the owner's answer · test: R3's watch-loop test · alternatives: B read the title once more when recording starts, then never; C read it once at the stop · status: active [agent-assumed 2026-11-16]
- **A3 · The organisation and account parts stay in the title.** flip at: the owner's answer · test: R2's text tests · alternatives: B keep only the meeting name, the part before the first " | " · status: active [agent-assumed 2026-11-16]
- **A4 · Recordings that already exist keep their titles and file names.** flip at: the owner's answer · test: none, no migration · alternatives: B strip "Meeting compact view | " from stored titles once, file names unchanged · status: active [agent-assumed 2026-11-16]
- **A5 · Only Teams gets the ranking and the refresh.** flip at: the owner's answer, or a report of the same problem for another app · test: R5's unchanged tests · alternatives: B the refresh for every app with meeting patterns (Zoom, Webex) · status: active [agent-assumed 2026-11-16]
- **A6 · When no window looks like the meeting window, another Teams window's title still names the recording before the placeholder does.** flip at: the owner's answer · test: R1's rank-4 test · alternatives: B the placeholder "Microsoft Teams Call" until a ranked window appears · status: active [agent-assumed 2026-11-16]
- **A7 · A diagnostics line with the rank and part count only records which window named the recording.** flip at: the owner's answer · test: R6's log test · status: active [agent-assumed 2026-11-16]
