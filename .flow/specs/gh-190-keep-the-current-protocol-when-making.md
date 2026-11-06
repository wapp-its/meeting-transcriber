# Keep the current protocol when making another one

## Conversation Evidence

> owner (session 2026-10-21, paraphrased): wants to make protocols for existing meetings again with other templates.
> owner (session 2026-10-21, answer to whether regenerating should change, paraphrased): also keep the old protocol, since one meeting may need a report for each of several audiences; the dialog must keep its template choice.
> owner (session 2026-10-21, selected): "Two specs (Recommended)": keeping the old protocol here, the template rules in a sibling spec (#189).
> owner (selected, 2026-10-28): "A: Mockups OK (Recommended)", the seven-board mockup of this spec and #189. Three boards belong here: the regenerate sheet with its new choice, the same sheet when the template already has a report, and the row menu listing the reports.
> owner (2026-10-30): "MOCKUP OK, all ok", which also keeps this spec's assumptions A1 to A4 as written.
> issue #170 (closed, shipped): the All Recordings window; a row's "…" menu (also on right-click) holds Open Protocol, Open Transcript, Show in Finder and Regenerate Protocol…, which opens the regenerate form as a sheet for that meeting; the toolbar holds "Regenerate from File…".
> issue #2 (closed, shipped): "Regenerate Protocol…" makes a meeting's protocol again with a chosen template and background info.

## Goal & Context

"Regenerate Protocol…" makes a finished meeting's protocol again with a chosen template and background info, and moves the previous protocol to the Trash, so a meeting has one protocol at a time. One meeting can need a report for each of several audiences, for example full minutes for the participants and a short summary for others. Today the user has to take the earlier protocol back out of the Trash and rename it by hand. With this spec the new protocol can be saved as an additional report next to the existing one.

<!-- Source: 0% user / 60% [paraphrase] / 40% [inferred] -->

## Architecture & Data Models

- **A meeting's files today:** the transcript `<basename>.txt` and the protocol `<basename>.md` in the output folder. That protocol stays the main protocol, with its role unchanged. A basename the app made has the form `<yyyyMMdd_HHmm>_<slug>_<short id>`, with no space or bracket in it. The mockup shortens these names for reading ("Budget review.md"); the sheet shows the real file names. [inferred]
- **Additional report:** a Markdown file in the same folder named `<basename> (<template name>).md`, so Finder sorts it next to the meeting. The template name is as the template picker shows it, except that the built-in template is called "Standard". It has the same document shape as a regenerated protocol. [inferred]
- **Finding them:** a meeting's additional reports are the files in its folder whose names begin with `<basename> (` and end with `).md`; the text between is the name the menu shows. Nothing else records them, so a report deleted or renamed in Finder drops out, and a report whose template was deleted later stays listed. [inferred]
- **Regenerate sheet (accepted mockup):** the template and background choice stay as they are. The meeting's lines gain the number of reports after the protocol's file name when there are any ("<file> · 1 additional report", "· 2 additional reports"). Between the background notice and the buttons comes the radio group "Save as:": [paraphrase]
  - "An additional report", with the small line "Saved as “<file>”. The current protocol stays as it is." When the chosen template already has a report, that line turns orange and reads "Replaces the existing “<file>”, which is moved to the Trash. The current protocol stays as it is."
  - "Replace the current protocol", with the small line "The current protocol is moved to the Trash and replaced."
- **All Recordings row (accepted mockup):** the "…" menu and the right-click menu show Open Protocol, Open Transcript and Show in Finder, then a separator, the non-interactive heading "Additional Reports" with one item per report in alphabetical order, another separator, and Regenerate Protocol…, followed by what gh-97 adds there. A row without reports shows neither the heading nor its separator. [paraphrase]

## Edge Cases & Constraints

- **No protocol yet** (protocol generation was off or failed): the result becomes the main protocol, as today, and the sheet offers no choice. [inferred]
- **Same template again:** saving an additional report for a template that already has one replaces that report the way Replace treats the main protocol, with the old file moved to the Trash; the main protocol is never touched. A user template named "Standard" shares its report file with the built-in template, so it counts as the same template here. [inferred]
- **Today's safety holds for both choices:** nothing is replaced when generation fails, when the meeting's files changed while the protocol was made, or when the write fails; the transcript is never changed. [inferred]
- **A name too long for the volume** fails with the existing write-failed message, and nothing is replaced. [inferred]
- **A pipeline retry** of the job rewrites only the main protocol and leaves additional reports alone. [inferred]
- **Files named by hand.** In "Regenerate from File…" a chosen file counts as an additional report only when its name has the shape above, no transcript with its own full name sits beside it, and the part before the first ` (` has a transcript or protocol beside it. Any other file resolves as today, so "Budget (Q3).md" with its own "Budget (Q3).txt" stays a meeting of its own. [inferred]
- **Privacy:** template names are user text and appear in log lines only as private values. [inferred]

## Acceptance Criteria

- **R1:** For a meeting that already has a protocol, the Regenerate Protocol sheet offers the radio group "Save as:" of the accepted mockup, with the template and background choice as today. An additional report is written to `<basename> (<template name>).md` next to the meeting's files, and the main protocol and every other report stay unchanged. Errors: a meeting without a protocol gets its main protocol as today, with no choice shown; an additional report for the same template is replaced and the old one moved to the Trash, which the sheet says in its orange line before the user generates; a failed generation, a failed write or meeting files that changed meanwhile leave every file as it was, with today's messages. [paraphrase]
- **R2:** A row in All Recordings lists each additional report of its meeting by its name under the heading "Additional Reports" in its "…" menu and its right-click menu, and choosing one opens that report. The row's main button and "Show in Finder" keep using the main protocol. Errors: a report deleted or renamed in Finder no longer appears the next time the menu opens. [paraphrase]
- **R3:** The main protocol stays the meeting's protocol everywhere else: "Open Protocol", "Open Last Protocol", the protocol path the automation API reports, and a pipeline retry, which rewrites only the main protocol. Errors: no error surface beyond R1. [inferred]
- **R4:** "Regenerate from File…" with an additional report chosen makes the protocol for that report's meeting (its transcript, title and start time), not for the report as a meeting of its own. Errors: when the meeting's transcript cannot be found, today's "No transcript was found" message. [inferred]
- **R5:** "Move Meeting to Trash…" (gh-97), for one row or a selection, also moves the meeting's additional reports to the Trash, and its confirmation counts them. "Move Audio to Trash…" and the automatic deletion leave them, like the transcript and the protocol. Errors: a report the Trash refuses leaves the meeting as "Deletion incomplete" with gh-97's retry. [inferred]

## Boundaries

- Several versions of a report for the same template: a second one replaces the first. [inferred]
- Additional reports in the automation API or in `/state`. [inferred]
- Additional reports made automatically when a meeting finishes (several templates per meeting from the start). [inferred]

## Decision Context

- **D1 · Making a protocol again can keep the current one and save the new one as an additional report, so one meeting can have reports for several audiences; the sheet keeps its template choice.** why: one meeting may need a report per audience · status: active [owner-stated 2026-10-21]
- **D2 · Keeping the old protocol and the template rules are two specs (this one and #189).** why: each ships on its own · status: active [owner-ratified 2026-10-21]
- **D3 · The accepted mockup is the layout and the wording: the radio group "Save as:" in the regenerate sheet with its two small lines, the orange line when the template already has a report, the number of reports in the sheet's meeting lines, and the heading "Additional Reports" with one item per report in the row menu.** why: the owner accepted the boards on 2026-10-28 ("Mockups OK") · status: active [owner-ratified 2026-10-28]
- **A1 · "Save as an additional report" is preselected when the meeting already has a protocol.** flip at: the owner wants Replace preselected · test: opening the sheet for a meeting with a protocol shows the additional-report choice selected · alternatives: Replace preselected, today's behaviour, where a forgotten switch sends the old protocol to the Trash · status: active [agent-assumed 2026-10-21]
- **A2 · An additional report is named `<basename> (<template name>).md` and found by that name; nothing else records it.** flip at: reports must survive a rename in Finder, or the list must know them without reading the folder · test: a report renamed in Finder drops out of the row's menu · status: active [agent-assumed 2026-10-21]
- **A3 · A second additional report with the same template replaces the first, with the old file moved to the Trash, instead of a numbered new file.** flip at: the owner wants every version kept · test: making the same template's report twice leaves one report and one file in the Trash · status: active [agent-assumed 2026-10-21]
- **A4 · The main protocol keeps its role everywhere (Open Protocol, Open Last Protocol, the automation API, a retry); a new additional report never becomes the main one.** flip at: the owner wants the latest report to be the one the row opens · test: R3 · status: active [agent-assumed 2026-10-21]
- **A5 · The built-in template's report is named `<basename> (Standard).md` and listed as "Standard", because its picker label "Standard (built-in)" would put brackets inside the brackets of the file name.** flip at: the report name of the built-in template · test: a report made with the built-in template is written under that name and listed as "Standard" · alternatives: B — use the picker label unchanged · status: active [agent-assumed 2026-11-06]
- **A6 · This spec builds after gh-97, and "Move Meeting to Trash…" takes the additional reports with it, because otherwise reports with the meeting's content stay behind in the output folder after the user deleted the meeting.** flip at: this spec's dependency on gh-97 and R5 · test: moving a meeting with two reports to the Trash leaves none of its files in the folder · alternatives: B — no dependency, reports stay behind until a follow-up · status: active [agent-inferred 2026-11-06]

Mockup gate: accepted by the owner on 2026-10-28. The boards are on a private design canvas, so this spec writes out their layout and wording; the example names in them ("Budget review", "Short summary") are examples.

Related: #2 and #170 (regenerate, shipped), #189 (sibling spec), gh-97 (delete recordings, builds first), #171 (transcribe and identify speakers again, the next row actions). Upstream check 2026-10-21: the original has no open issue or pull request about several protocols per meeting; templates and "Regenerate Protocol…" exist only in this fork.
