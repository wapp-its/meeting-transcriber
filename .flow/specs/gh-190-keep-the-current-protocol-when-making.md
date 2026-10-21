# Keep the current protocol when making another one

## Conversation Evidence

> owner (session 2026-10-21, paraphrased): wants to make protocols for existing meetings again with other templates.
> owner (session 2026-10-21, answer to whether regenerating should change, paraphrased): also keep the old protocol, since one meeting may need a report for each of several audiences; the dialog must keep its template choice.
> owner (session 2026-10-21, selected): "Two specs (Recommended)": keeping the old protocol here, the template rules in a sibling spec (#189).
> issue #170 (closed, shipped): the All Recordings window; a row's "…" menu (also on right-click) holds Open Protocol, Open Transcript, Show in Finder and Regenerate Protocol…, which opens the regenerate form as a sheet for that meeting; the toolbar holds "Regenerate from File…".
> issue #2 (closed, shipped): "Regenerate Protocol…" makes a meeting's protocol again with a chosen template and background info.

## Goal & Context

"Regenerate Protocol…" makes a finished meeting's protocol again with a chosen template and background info, and moves the previous protocol to the Trash, so a meeting has one protocol at a time. One meeting can need a report for each of several audiences, for example full minutes for the participants and a short summary for others. Today the user has to take the earlier protocol back out of the Trash and rename it by hand. With this spec the new protocol can be saved as an additional report next to the existing one.

<!-- Source: 0% user / 60% [paraphrase] / 40% [inferred] -->

## Architecture & Data Models

- **A meeting's files today:** the transcript `<basename>.txt` and the protocol `<basename>.md` in the output folder. That protocol stays the main protocol, with its role unchanged. [inferred]
- **Additional report:** a Markdown file in the same folder named `<basename> (<template name>).md`, the template name as the template picker shows it, so Finder sorts it next to the meeting. It has the same document shape as a regenerated protocol. [inferred]
- **Finding them:** a meeting's additional reports are the files in its folder whose names have that shape for its basename. Nothing else records them, so a report deleted or renamed in Finder drops out. [inferred]
- **Regenerate sheet:** a choice between replacing the current protocol and saving an additional report; the template and background choice stay as they are. [paraphrase]
- **All Recordings row:** the "…" menu and the right-click menu gain one item per additional report, named by its template. [paraphrase]

## Edge Cases & Constraints

- **No protocol yet** (protocol generation was off or failed): the result becomes the main protocol, as today, and the sheet offers no choice. [inferred]
- **Same template again:** saving an additional report for a template that already has one replaces that report the way Replace treats the main protocol, with the old file moved to the Trash; the main protocol is never touched. [inferred]
- **Today's safety holds for both choices:** nothing is replaced when generation fails, when the meeting's files changed while the protocol was made, or when the write fails; the transcript is never changed. [inferred]
- **A name too long for the volume** fails with the existing write-failed message, and nothing is replaced. [inferred]
- **A pipeline retry** of the job rewrites only the main protocol and leaves additional reports alone. [inferred]
- **Privacy:** template names are user text and appear in log lines only as private values. [inferred]

## Acceptance Criteria

- **R1:** For a meeting that already has a protocol, the Regenerate Protocol sheet offers saving the new protocol as an additional report, besides replacing the current one, with the template and background choice as today. An additional report is written to `<basename> (<template name>).md` next to the meeting's files, and the main protocol and every other report stay unchanged. Errors: a meeting without a protocol gets its main protocol as today, with no choice shown; an additional report for the same template is replaced and the old one moved to the Trash; a failed generation, a failed write or meeting files that changed meanwhile leave every file as it was, with today's messages. [paraphrase]
- **R2:** A row in All Recordings lists each additional report of its meeting by template name in its "…" menu and its right-click menu, and choosing one opens that report. The row's main button and "Show in Finder" keep using the main protocol. Errors: a report deleted or renamed in Finder no longer appears the next time the menu opens. [paraphrase]
- **R3:** The main protocol stays the meeting's protocol everywhere else: "Open Protocol", "Open Last Protocol", the protocol path the automation API reports, and a pipeline retry, which rewrites only the main protocol. Errors: no error surface beyond R1. [inferred]
- **R4:** "Regenerate from File…" with an additional report chosen makes the protocol for that report's meeting (its transcript, title and start time), not for the report as a meeting of its own. Errors: when the meeting's transcript cannot be found, today's "No transcript was found" message. [inferred]

## Boundaries

- Several versions of a report for the same template: a second one replaces the first. [inferred]
- Additional reports in the automation API or in `/state`. [inferred]
- Additional reports made automatically when a meeting finishes (several templates per meeting from the start). [inferred]

## Decision Context

- **D1 · Making a protocol again can keep the current one and save the new one as an additional report, so one meeting can have reports for several audiences; the sheet keeps its template choice.** why: one meeting may need a report per audience · status: active [owner-stated 2026-10-21]
- **D2 · Keeping the old protocol and the template rules are two specs (this one and #189).** why: each ships on its own · status: active [owner-ratified 2026-10-21]
- **A1 · "Save as an additional report" is preselected when the meeting already has a protocol.** flip at: the owner wants Replace preselected · test: opening the sheet for a meeting with a protocol shows the additional-report choice selected · alternatives: Replace preselected, today's behaviour, where a forgotten switch sends the old protocol to the Trash · status: active [agent-assumed 2026-10-21]
- **A2 · An additional report is named `<basename> (<template name>).md` and found by that name; nothing else records it.** flip at: reports must survive a rename in Finder, or the list must know them without reading the folder · test: a report renamed in Finder drops out of the row's menu · status: active [agent-assumed 2026-10-21]
- **A3 · A second additional report with the same template replaces the first, with the old file moved to the Trash, instead of a numbered new file.** flip at: the owner wants every version kept · test: making the same template's report twice leaves one report and one file in the Trash · status: active [agent-assumed 2026-10-21]
- **A4 · The main protocol keeps its role everywhere (Open Protocol, Open Last Protocol, the automation API, a retry); a new additional report never becomes the main one.** flip at: the owner wants the latest report to be the one the row opens · test: R3 · status: active [agent-assumed 2026-10-21]

Mockup gate: no accepted mockup yet for the regenerate sheet's choice and the row menu; plan and work wait for it (owner rule 2026-10-14: screens are drawn and accepted before code).

Related: #2 and #170 (regenerate, shipped), #189 (sibling spec), #171 (transcribe and identify speakers again, the next row actions). Upstream check 2026-10-21: the original has no open issue or pull request about several protocols per meeting; templates and "Regenerate Protocol…" exist only in this fork.
