# A meeting's reports in one place

## Conversation Evidence

The fork is public, so the owner's turns are paraphrased, not quoted.

> owner (paraphrased, 2026-11-19): no click shows all of a meeting's reports.
> owner (paraphrased, 2026-11-19): took the review's recommendation for its decision 2: "Replace the notes" keeps the old notes as a listed earlier version and does not move them to the Trash.
> owner (paraphrased, 2026-11-19): took the review's recommendation for its decision 3: "Show All in Finder" selects the meeting's files in the notes folder and moves no file.
> review (2026-11-19, code reading and renders with made-up meetings; nothing was driven live): "Show in Finder" selects the main notes only, reports are separate items in the "…" menu under an inert heading, "Open Notes Folder" opens the folder above the notes, and earlier versions (`.previous-` and Transcribe Again's `.until-` files) are listed nowhere. "Replace the current notes" sends the old notes to the Trash, while Transcribe Again keeps them beside the meeting.

## Goal & Context

<!-- Source: 0% user / 60% [paraphrase] / 40% [inferred] -->

A user sees at a glance which notes and reports a meeting has, and can open, reveal or remove each one. After this spec a finished row shows a reports line, the "…" menu has a Reports submenu with the earlier versions, and "Show All in Finder" selects every file of the meeting. Nothing generated disappears without a click: replaced notes are kept as an earlier version, as Transcribe Again already keeps them. [paraphrase]

This spec builds on "Notes made again are kept and show up" (gh-278), which numbers additional reports instead of replacing them and makes "Show in Finder" select the meeting's notes, transcript and reports. It waits for a mockup of the row's reports line and the Reports submenu. [inferred]

Stands on the original: no. It builds on gh-170 (All Recordings) and gh-190 (additional reports), which exist only in the fork. Related in the original: its open issue 873, a prototype of a separate "Meetings" window with notes and transcript side by side, with no pull request yet; if that window is merged there, the two windows need reconciling (watched in #282). Related fork work: #197 (additional reports to Notion), #201 (no file reads while the list is drawn). [inferred]

## Architecture & Data Models

<!-- Source: 0% user / 40% [paraphrase] / 60% [inferred] -->

- **One set of main notes, any number of additional reports, and earlier versions.** Reports are found by the ownership rule (`AdditionalReport`, `MeetingReportFolder`). Earlier versions are replaced notes (`.previous-<stamp>.md`), Transcribe Again's earlier notes (`.until-<stamp>`, `EarlierVersionName`) and a report the Trash refused; each is listed with its date. [paraphrase]
- **Replace keeps.** "Replace the notes" renames the old notes to their earlier-version name beside the meeting instead of trashing them, as Transcribe Again does, and the meeting's record lists the file so Move Meeting to Trash takes it along (D1). [paraphrase]
- **Reading stays off the draw.** The reports line and the submenu use what the row read when the window came to the front or after a row action (`RowAvailability`), never a file read while a row is drawn (#201). [inferred]

## API Contracts

- No new endpoint; All Recordings stays off the `/ui/tree` and `/ui/press` window allowlist, since it shows meeting content. [inferred]

## Edge Cases & Constraints

- **Names that do not fit** the row read "Notes · 3 reports". [paraphrase]
- **A report deleted or renamed in Finder** drops out at the next read, as today. [inferred]
- **Files on a volume that does not answer** leave the line and the submenu as last read, and the window does not wait (#201). [inferred]
- **Privacy:** file names carry meeting titles, so they stay out of log lines. [inferred]

## Acceptance Criteria

- **R1:** A finished row with additional reports shows a line under the summary, "Notes · Short · Board summary", where each name opens its file. When the names do not fit, the line reads "Notes · 3 reports". Errors: a file that is gone at the click says "The file was moved or deleted." as today. [paraphrase]
- **R2:** The "…" menu has a "Reports" submenu in place of the "Additional Reports" group. It lists the main notes and each report with template and date (each opens) and ends with "Show All in Finder". No error surface beyond R1. [paraphrase]
- **R3:** Earlier versions (replaced notes, Transcribe Again's `.until-` files, a report the Trash refused) are listed under "Earlier versions" in that submenu with their date. No error surface beyond R1. [paraphrase]
- **R4:** A report or an earlier version can be moved to the Trash after a confirmation that names the file. The main notes cannot be. Errors: a Trash that refuses says so and keeps the file listed. [paraphrase]
- **R5:** "Replace the notes" keeps the old notes as an earlier version, and Move Meeting to Trash takes them along (D1). Errors: a rename that fails leaves the old notes in place and writes nothing, as today. [paraphrase]
- **R6:** A finished row's "…" menu has at most 10 top-level entries. No error surface beyond the menu. [paraphrase]
- **R7:** Optional, filed if not built: while a recording runs, the list shows it as the top row with Stop. No error surface beyond today's Stop. [paraphrase]

## Boundaries

- No subfolder per meeting and no file moves (D2). [paraphrase]
- No detail pane with notes and transcript inside the window; that can follow if the original's issue 873 lands. [paraphrase]
- Writing notes as a visible job belongs to "Writing notes is a visible job". [paraphrase]
- `CLAUDE.md` and `AGENTS.md` stay unchanged. [inferred]

## Decision Context

- **D1 · "Replace the notes" keeps the old notes beside the meeting as a listed earlier version and does not move them to the Trash; Move Meeting to Trash takes them along.** why: the owner took the review's recommendation B for its decision 2 (paraphrased): nothing generated is lost without a click, and it matches Transcribe Again · alternatives: A — move them to the Trash, as today · status: active [owner-stated 2026-11-19]
- **D2 · "Show All in Finder" selects every file of the meeting (notes, reports, transcript) in the shared notes folder, and no file moves.** why: the owner took the review's recommendation A for its decision 3 (paraphrased): the smallest change that answers where all its reports are, and backups, retention and the original's layout stay as they are · alternatives: B — one subfolder per meeting; C — a detail pane beside the list · status: active [owner-stated 2026-11-19]

Mockup gate: needed (row reports line and Reports submenu); no code before the owner accepts the boards.
