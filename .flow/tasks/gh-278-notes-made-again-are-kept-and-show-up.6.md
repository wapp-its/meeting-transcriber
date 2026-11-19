---
satisfies: [R5, R6, R8, R9]
---
# gh-278-notes-made-again-are-kept-and-show-up.6 Regenerate sheet: another meeting's run, the background box and the result lines

## Description
The regenerate sheet: another meeting's run no longer shows in a sheet opened for a different meeting (R5), "Background info" is a bordered box without a stray scroller (R6), and the title and success lines say what happened (R8, the sheet part, A8). It comes after .1 and .3, which change the same run code and give the report name the success line shows.

**Size:** M
**Files:** `Sources/ProtocolRegeneration.swift`, `Sources/RegenerateSheetState.swift`, `Sources/RegenerateProtocolView.swift`, `Sources/ProtocolOptionsForm.swift`, possibly a new `Sources/BackgroundTextBox.swift`, `docs/architecture-macos.md`; tests `Tests/RegenerateProtocolViewTests.swift`, `Tests/RegenerateSaveAsTests.swift`, `Tests/RegenerateSheetStateTests.swift`, `Tests/ProtocolOptionsFormTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/ProtocolRegeneration.swift, app/MeetingTranscriber/Sources/RegenerateSheetState.swift, app/MeetingTranscriber/Sources/RegenerateProtocolView.swift, app/MeetingTranscriber/Sources/ProtocolOptionsForm.swift, app/MeetingTranscriber/Sources/BackgroundTextBox.swift, app/MeetingTranscriber/Tests/RegenerateProtocolViewTests.swift, app/MeetingTranscriber/Tests/RegenerateSaveAsTests.swift, app/MeetingTranscriber/Tests/RegenerateSheetStateTests.swift, app/MeetingTranscriber/Tests/ProtocolOptionsFormTests.swift, docs/architecture-macos.md]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first: the sheet test for another meeting's run fails on today's code.
1. **Which meeting runs.** While running, the regenerator exposes the meeting it writes for (its job id, else its folder and basename, and its title), set together with `.running` and kept with the finished phase, so the sheet can tell whose result it is. A value beside `phase`, rather than a payload on `Phase.running`, keeps the `== .running` comparisons as they are (`Sources/ProtocolRegeneration.swift:194`, `Sources/RegenerateProtocolView.swift:129,152,246`, `Sources/TranscriptionsView.swift:400`, and in `Tests/RegenerateProtocolViewTests.swift:106`, `Tests/RegenerateSaveAsTests.swift:132`, `Tests/TranscriptionsViewTests+*.swift`).
2. **Sheet** (`Sources/RegenerateProtocolView.swift:127-134,241-265`): for another meeting's run, the line "Notes for “A” are being written. You can start these when they are done." in place of the spinner, and Generate disabled; it never shows that run's result, also after the run ends, when Generate is enabled again. A sheet for the running meeting itself shows the run as today. For "Regenerate from File…" the comparison uses the target resolved from the chosen file. `RegenerateSheetState.present` (`Sources/RegenerateSheetState.swift:29-39`) keeps clearing only a finished result.
3. **Wording** (R8, A8): the title "Write Meeting Notes" when the meeting has no notes, else "Regenerate Meeting Notes" (`:134`); the success line (`:254`) "Report “<name>” saved" for an additional report (the name from the written file `<basename> (<name>).md`, so "Short 2" after .1), "Notes replaced" when notes were replaced, "Notes saved" for a meeting's first notes.
4. **Background box** (R6, `Sources/ProtocolOptionsForm.swift:81-95`): a bordered text box whose scroll view sets `autohidesScrollers`, so no scroller shows while the text fits, also with "Show scroll bars: Always". An `NSViewRepresentable` around `NSTextView.scrollableTextView()` follows `Sources/Settings/CommandProviderSettingsView.swift:73-118`; keep the binding, the identifier and the minimum height. The form is shared with `Sources/ConsentOptionsView.swift:80` and `Sources/AppPickerView.swift:194` (fixed height through `onLineHeightChange`), which get the same box; check that both still lay out.
5. **Docs**, in the same change: `docs/architecture-macos.md` § Additional Reports, the sentence on the sheet after a run (`:808-810`), for a run of another meeting.

Tests:
- ViewInspector (`makeView(phase:)` at `Tests/RegenerateProtocolViewTests.swift:27-50`; `callOnChange` at `Tests/RegenerateSaveAsTests.swift:122-140`): B's sheet while A runs → the line with A's title, no spinner, Generate disabled; A ends with success → B shows no result and Generate is enabled; A's own sheet as today; the two titles; the three success lines.
- Background box: the view it makes has a border and a scroll view with `autohidesScrollers == true` (unit test on the made `NSView`, pattern `Tests/CommandProviderSettingsViewTests.swift:53`). `Tests/ProtocolOptionsFormTests.swift:52-60` finds a `TextEditor` by identifier; move it to the new view (the control changed with the requirement), keeping the binding test.
- The look under "Show scroll bars: Always" is a person's check in the dev build, not part of this task's tests; say so in the done summary.

### Investigation targets
**Required** (read before coding):
- `Sources/ProtocolRegeneration.swift:136-200,245-270` — `Phase`, `isRunning`, `clearResult`, the run's start and end
- `Sources/RegenerateProtocolView.swift` — title, status block, Generate state
- `Sources/RegenerateSheetState.swift` — `present`
- `Sources/ProtocolOptionsForm.swift` — `backgroundEditor`, `onLineHeightChange`
- `Sources/Settings/CommandProviderSettingsView.swift:73-118` — an `NSTextView` representable in this app

**Optional** (reference as needed):
- `Tests/RegenerateProtocolViewTests.swift`, `Tests/RegenerateSaveAsTests.swift` — sheet test helpers
- `docs/architecture/gui-testing.md` — ViewInspector and A11yID rules

## Acceptance
- [ ] A sheet for meeting B while A's notes are written shows the line naming A, no spinner, Generate disabled, and never A's result; after A ends, Generate is enabled; A's own sheet behaves as today.
- [ ] Title "Write Meeting Notes" without notes; success lines "Report “<name>” saved", "Notes replaced", "Notes saved".
- [ ] "Background info" is a bordered box whose scroller hides while the text fits; the consent and app-picker forms still lay out.
- [ ] `docs/architecture-macos.md` describes the sheet during another meeting's run.
- [ ] Each new or changed test fails on the code before this task.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
