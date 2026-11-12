# Show the last recording in its own menu section

## Conversation Evidence

> user (paraphrased, 2026-10-21): the reworked menu looks fine, but the details of the last meeting should move down to the recordings, or into a section of their own called "Last Recording", and the item that opens the protocol should move there too.
> user (2026-11-12, selected): "B — Own Last Recording section" (preview: a "Last Recording" heading over the recording's name, a line with its app and time, and the open item with ⌘O; below it a "Recordings" heading over "All Recordings…" with ⌘T)

## Goal & Context

The menu's open item for the newest result ("Open Last Notes", ⌘O) sits under "Recordings" and does not say which recording it opens. The owner wants the newest finished recording named in the menu, in a section of its own, with the open item right under its name, so a glance shows what ⌘O will open.

The meeting lines at the top of the menu are not part of this. They show only while a recording runs: the lines that used to stay there after a meeting ended are already cleared when the recording ends.

<!-- Source: 60% [paraphrase] / 40% [inferred] -->

## Architecture & Data Models

The menu already finds the newest finished recording with something to open: it merges the live job queue with the persisted job history into one list of recordings (the same list the All Recordings window shows), picks the newest finished entry, and resolves where its open item goes (the local notes file, or the Notion page when Notion export prefers it). The new section reads that same entry and that same open target; nothing new is stored or persisted.

The details line is plain text built from the entry, kept apart from the view so it can be tested without the menu, the way the All Recordings window builds its row lines.

<!-- Source: 20% [paraphrase] / 80% [inferred] -->

## Edge Cases & Constraints

- While a recording runs or a job is still in progress, the section keeps showing the newest finished recording; a job that is running, waiting for speaker names or failed never replaces it (it shows under "In progress" or "Needs you" as today). [inferred]
- The history survives a restart, so the section does too, as the open item does today. [inferred]
- A long recording name is shown as the All Recordings window shows it, without extra shortening. [inferred]
- A recording whose result went only to Notion has no local file; the open item opens the Notion page, as it does today. [inferred]

## Acceptance Criteria

- **R1:** When the newest finished recording has something to open, the menu shows a section headed "Last Recording" directly above the "Recordings" section, holding in this order: the recording's name, a details line with its app and time, and the open item with ⌘O. [paraphrase] Errors: when no finished recording has something to open (none yet, or the newest finished ones have no file and no Notion page), the section is left out together with its heading; there is never an empty heading.
- **R2:** The name, the details line and the open item describe the same recording: the newest finished one, which is the one the open item opens. [paraphrase] Errors: no error surface beyond R1.
- **R3:** The details line reads "<app> · <day and time>": the day is "Today" or "Yesterday" for those days and the abbreviated date otherwise, followed by the time, in the user's locale; the time is the recording's start, or when the job was queued when no start was captured (as the All Recordings window does). [inferred] Errors: an unknown app leaves only the day and time; no time leaves only the app; with neither, the details line is left out and the name stays.
- **R4:** The name and the details line are not actions: choosing them does nothing, like the meeting lines at the top of the menu. [inferred] Errors: no error surface beyond R1.
- **R5:** The "Recordings" section holds only "All Recordings…" with ⌘T, shown at all times as today; the open item no longer appears there. [paraphrase] Errors: no error surface beyond R1.
- **R6:** The open item keeps its ⌘O shortcut, its action and its accessibility identifier; its label is "Open Notes", or "Open in Notion" when it opens the Notion page (the wording of the All Recordings window). [inferred] Errors: no error surface beyond R1.

## Boundaries

- The meeting lines at the top of the menu stay as they are. [inferred]
- The All Recordings window does not change. [inferred]
- No new setting, and no change to which recording counts as the newest or where the open item goes. [inferred]

## Decision Context

- **D1 · The newest finished recording gets its own "Last Recording" section above "Recordings", with its name, a details line and the open item; "Recordings" keeps only "All Recordings…".** why: the open item did not say which recording it opens; the owner picked this layout (preview B) over putting the same lines inside "Recordings", and the picked preview is the accepted mockup for this menu change · alternatives: the lines inside "Recordings" (preview A) · status: active [owner-ratified 2026-11-12]
- **A1 · The open item reads "Open Notes", or "Open in Notion" for a Notion page, instead of "Open Last Notes".** flip at: the open item's label · test: the label test for both open targets · status: active [agent-assumed 2026-11-12]
- **A2 · A missing app or time is left out of the details line instead of shown as "—", and a line with neither is left out.** flip at: the details-line builder · test: the details-line tests for a missing app, a missing time and both · status: active [agent-assumed 2026-11-12]
- **A3 · The day reads "Today" or "Yesterday" for those days, otherwise the abbreviated date, in the user's locale.** flip at: the details-line builder · test: the details-line tests for today, yesterday and an older day · status: active [agent-inferred 2026-11-12]
- **A4 · The details line joins the day and the time with "at", as macOS and the All Recordings window write a day with a time in English: "Teams · Today at 10:30", "Zoom · 10 Nov 2026 at 9:00". The time and the abbreviated date are written in the user's locale; "Today", "Yesterday" and "at" stay English like the rest of the app.** flip at: the details-line builder · test: the details-line tests for today, yesterday, an older day and a second locale · status: active [agent-assumed 2026-11-12]
