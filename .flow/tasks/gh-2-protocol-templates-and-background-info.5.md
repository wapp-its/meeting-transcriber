---
satisfies: [R10]
---
# gh-2-protocol-templates-and-background-info.5 Template choice in the pending recording prompt (after gh-49)

## Description
Adds "Record with Options…" to the pending-prompt menu section that spec `gh-49-show-a-pending-recording-prompt-on-the` builds (spec "Recording prompt (after spec gh-49)", R10, D2). It is last because it needs gh-49's code on `wapp/main` (the coordinator sets the spec-level dependency) and task 3's options form, and it edits the same menu and scene files as task 4.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchLoop+Consent.swift`, `Sources/WatchLoop.swift`, new `Sources/ConsentOptionsView.swift`, `Sources/MenuBarView.swift`, `Sources/MeetingTranscriberApp.swift`, `Sources/AppState.swift`, `Sources/A11yID.swift`, tests
**Touches:** [app/MeetingTranscriber/Sources/WatchLoop+Consent.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/ConsentOptionsView.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/WatchLoopConsentOptionsTests.swift, app/MeetingTranscriber/Tests/ConsentOptionsViewTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift]

### Approach
- First read what gh-49 merged: `ConsentQuestion` (app, title, body), `WatchLoop.pendingConsentQuestion`, `WatchLoop.answerParkedConsent(_:granted:) -> Bool` (identity check, then `notifier.resolveBrowserConsent(granted:)`), and the `MenuBarView` consent section with `consentQuestion` / `onAnswerConsent`. If any of these differ from that spec's names, follow the merged code and say so in the done summary.
- Loop (tests first, pattern `Tests/WatchLoopAskBeforeRecordingTests.swift` / `Tests/WatchLoopBrowserConsentTests.swift`): `answerParkedConsent(_:granted:protocolOptions:)` (default nil) stores the options in `pendingConsentProtocolOptions` before resolving; `finishConsent` reads them before `clearConsentState()` and, only when it sets `approvedConsentMeeting`, sets `approvedConsentProtocolOptions`; `clearConsentState()` clears both new fields; the poll loop takes the options together with the approved meeting and passes them through `runMeeting`/`handleMeeting` to `enqueueRecording(…, protocolOptions:)` (task 3 added that parameter). Every dropped grant (watching stopped, another recording running, the call ended) drops the options with it.
- `ConsentOptionsView` (window id `record-meeting-options`, title "Record Meeting"): the question's title and body as posted, the `ProtocolOptionsForm` with a fresh draft, Record (`A11yID.consentOptionsRecordButton`) and Cancel. Record calls `AppState`'s answer with the question it displays; on `false` (question no longer open) it shows "This question is no longer open, so nothing was recorded." and stays open; on success it closes. Cancel only closes. `AppState` keeps the question the window was opened for.
- Menu: a third button "Record with Options…" in gh-49's consent section, handing back the displayed question; it opens the window via `bringWindowToFront(id:)`.
- Never add `record-meeting-options` to the `/screenshot`, `/ui/tree` or `/ui/press` allowlists.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchLoop+Consent.swift` — gate, answer path and `finishConsent` (as merged by gh-49)
- `app/MeetingTranscriber/Sources/WatchLoop.swift:86-117,310-430` — consent state fields, `clearConsentState`, poll loop, `runMeeting`, `handleMeeting`
- `app/MeetingTranscriber/Sources/MenuBarView.swift` — gh-49's consent section

**Optional** (reference as needed):
- `.flow/specs/gh-49-show-a-pending-recording-prompt-on-the.md` (once merged) — the answer-path contract (its A1) and menu section
- `app/MeetingTranscriber/Tests/WatchLoopAskBeforeRecordingTests.swift` — consent answer tests with fake notifier and recorder

### Key context
- A notification answer, the menu's plain Record and `POST /action/confirmBrowserConsent` carry no options; only this window's Record does.
- The options belong to one question: a stale or replaced question must never carry options into another meeting's recording.
- Do not edit `CLAUDE.md` or `AGENTS.md`.
## Acceptance
- [ ] Answering an open prompt with options starts the recording through the existing approval path and the enqueued job carries that template and background (R10).
- [ ] A notification answer and the menu's plain Record leave the job with the stamped default and no background (R10, R4).
- [ ] A stale or replaced question returns false, starts nothing and attaches no options to any later recording; a dropped grant (watching stopped, another recording running, call ended) drops the options (R10).
- [ ] ViewInspector: "Record with Options…" hands back the displayed question; the window shows the question's title and body; Record calls the answer with the draft's options; a false answer shows the no-longer-open text; Cancel does not answer (R10).
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<scratch> swift test --parallel --skip WatchLoopE2ETests --filter "WatchLoop|Consent|MenuBar|AppState" > /private/tmp/<scratch>/t5.log 2>&1` passes (read the log file).
- [ ] `./scripts/lint.sh` passes with the pinned tools, and `swift build -c release -Xswiftc -DAPPSTORE` compiles.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
