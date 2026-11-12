# Create and open templates in the app you choose

## Conversation Evidence

> owner (session 2026-11-12, paraphrased): the name field for a new template sits inline in the settings list and does not look like an input field, so it is hard to see; a small window asking for the name would be better.
> owner (session 2026-11-12, paraphrased): after a template is created or edited, the Markdown file opens in the Mac's default app, which may not be the editor wanted; being able to choose the app, or getting the file shown in Finder to open it with any app, would solve it, together with a note that explains what happens. The aim is to avoid building an editor into the app.
> owner (session 2026-11-12, asked): whether an editor inside the app could make sense, and whether the project already has one to reuse. Answer given: the app has only two plain text boxes (a meeting's background info in the start window, the terminology rules in Settings), with no Markdown support; the original project has no editor either.
> owner (selected, 2026-11-12): "A: Popup + Open With (Recommended)", over "B: Popup + Finder only" and "C: In-app editor".
> owner (selected, 2026-11-12): "Spec + mockups, build here (Recommended)".
> owner (selected, 2026-11-12): "A: Mockups OK (Recommended)", the four boards 207·1 to 207·4.

## Goal & Context

Meeting-notes templates (fork feature #116) are Markdown files in the templates folder. In Settings → Output, the section "Meeting Notes Templates" lists them with Edit and Delete, and a text field "New template name" with "Create Template" below the list; Edit and Create open the file with the Mac's default app for Markdown. The field is easy to miss, and the default app may not be the editor the user wants. This spec moves the name into a "New Template…" window that says what happens next, and turns Edit into a split button that opens the template in the app the user chose last, with Open With and Show in Finder in its menu. Templates stay files edited outside the app; no editor is built in. [paraphrase]

The original project has no template feature: its single prompt file opens outside the app through "Edit Prompt". No issue or pull request there asks for this, so the change stays in the fork. [inferred]

<!-- Source: 0% user / 70% [paraphrase] / 30% [inferred] -->

## Architecture & Data Models

- **Section layout (accepted mockup, board 207·1):** the default template picker stays first. Each template row shows its name, then the split button "Edit" with an arrow, then "Delete". Below the rows, one line holds "New Template…" (with a plus sign) and "Open Templates Folder". Under them the help text reads: "Templates are Markdown files in the templates folder. Edit opens one in <app>. To use another app, click the arrow beside Edit and choose Open With; the app remembers your choice. {LANGUAGE}, {MEETING_DATE} and {MEETING_TIME} are filled in for every template. Background info entered for a meeting is added to the prompt automatically." The inline name field and "Create Template" are removed. [paraphrase]
- **The Edit split button:** clicking "Edit" opens the template in the editor app (below). The arrow opens a menu: "Open in <app>", a separator, "Open With" with a submenu, and "Show in Finder". The submenu lists the apps macOS offers for that file, the Mac's default app first with "(default)" after its name, the others by name, then a separator and "Other…", which lets the user pick any app. [paraphrase]
- **The editor app:** the app the user chose last under Open With or Other…, remembered across launches by its bundle identifier in the app's settings, and used by every row's Edit and by a newly created template. With no remembered app, the editor app is the Mac's default app for the file. `<app>` in the menu, the help text and the window's note is that app's name as Finder shows it, without ".app". [inferred]
- **New Template window (accepted mockup, boards 207·2 and 207·3):** "New Template…" opens a sheet on the Settings window, titled "New Template", with a "Name" field that has the focus, a note with an info icon, and "Cancel" and "Create" (the default button). The note reads: "Creates “<name>.md” in the templates folder from the built-in template and opens it in <app>, where you change and save it. To use another app, click the arrow beside Edit and choose Open With." A name the store refuses shows the store's existing message in red under the field ("A template with this name already exists.", and the others for an empty, too long, slash or colon, or leading-dot name) and disables Create. [paraphrase]
- **Opening fails (accepted mockup, board 207·4):** when the editor app cannot open the file, the app shows the file selected in Finder and puts an orange line with a warning icon under "New Template…": "<app> could not open “<file>”, so it is shown in Finder. Open it from there with any app, or choose another app under Open With." [paraphrase]
- **Seams (plan):** `ProtocolTemplatesModel` today takes `openFile: (URL) -> Void`. It gains one injected opener value with the operations the section needs: the default app for a file, the apps for a file, open a file with a given app (reporting failure), reveal a file in Finder, and ask the user to pick an app (an open panel limited to applications). The real one wraps `NSWorkspace` and `NSOpenPanel`; tests inject a fake. `AppSettings` gains the remembered editor's bundle identifier (absent by default). The model holds the sheet's state (shown, typed name, the live refusal, the write error) instead of the inline `newName`. `OutputSettingsView` keeps building the model, as today. [inferred]
- **Both builds:** the Homebrew and the App Store build behave the same; opening a file with another app, revealing it and picking an app all work inside the sandbox, which has the user-selected-file entitlement. [inferred]

## Edge Cases & Constraints

- **The remembered app is no longer installed:** treated like an app that cannot open the file (board 207·4's line with "was not found" instead of "could not open"), and the app forgets it, so the next Edit uses the default app. [inferred]
- **No app on the Mac opens Markdown files:** Edit and Create show the file in Finder with the orange line "No app is set to open Markdown files, so “<file>” is shown in Finder. Open it from there with any app, or choose an app under Open With."; the menu leaves out "Open in <app>", Open With lists only "Other…", and the help text and the window's note say the file is shown in Finder. [inferred]
- **The write fails in the window** (for example a full disk): the window stays open with the typed name and shows the error in red under the field; nothing opens. [inferred]
- **Cancel or Escape** closes the window without writing; Return presses Create when it is enabled. [inferred]
- **Another app changed the folder while the window is open:** the refusal is checked again when Create is pressed, so a name taken meanwhile is refused there. [inferred]
- **The orange line** disappears on the next successful open, create, delete or folder open, like today's message. [inferred]
- **Privacy:** template names are user text and appear in log lines only as private values; app names and bundle identifiers are not personal. [inferred]

## Acceptance Criteria

- **R1:** The section "Meeting Notes Templates" shows the layout and wording of board 207·1: the default picker, each template with the split button Edit and Delete, the line with "New Template…" and "Open Templates Folder", and the help text naming the editor app. The inline name field and "Create Template" are gone. Errors: none beyond R4. [paraphrase]
- **R2:** "New Template…" opens the New Template window of board 207·2. Create writes "<name>.md" from the built-in template, closes the window, lists the template and opens it in the editor app. Errors: a refused name shows its message in red and disables Create (board 207·3); a failed write keeps the window open with the name and shows the error; Cancel and Escape write nothing. [paraphrase]
- **R3:** A template's Edit opens it in the editor app. Its menu offers "Open in <app>", "Open With" with the apps macOS offers for the file (default first, marked) and "Other…", and "Show in Finder", which shows the file selected in Finder. Choosing an app under Open With or Other… opens the template in it and makes it the editor app for every template, also after a relaunch. Errors: R4. [paraphrase]
- **R4:** When the editor app cannot open a template, is no longer installed, or no app opens Markdown files, the file is shown selected in Finder and the section shows the orange line of board 207·4 with the matching reason; a missing remembered app is forgotten. Errors: when Finder cannot show the file either, the line names that error. [inferred]
- **R5:** The default template picker, Delete with its confirmation, Open Templates Folder and the template rules work as before. Errors: none new. [inferred]

## Validation

Test first, from the criteria, at the cheapest layer that can fail:

1. **Choosing the app (pure logic):** remembered app present → that app; remembered app missing → Finder and forgotten; nothing remembered → the default app; no default app → Finder; the Open With list puts the default first with "(default)", sorts the others, lists each app once and ends with "Other…".
2. **The model, with a fake opener and a temporary folder:** Create writes the file, closes the window and opens it with the editor app; a refused name shows each existing message and keeps Create disabled; an empty name disables Create without a red line; a failed write keeps the window and the name; Open With and Other… store the bundle identifier and open the file; a failed open reveals the file and sets the orange line in each wording; Show in Finder reveals the file.
3. **The settings (existing settings tests):** the bundle identifier survives a reload of the settings and is absent by default.
4. **The view (one ViewInspector wiring test per control, with the existing section tests):** New Template… presents the sheet; Name, Cancel and Create reach the model; Edit's primary action and each menu item reach the model; the help text and the note name the editor app; the old field and button are gone.
5. **Both build variants:** the suite runs for the Homebrew and the App Store build, as CI does.
6. **Look:** how the split button, the menu and the window look stays the owner's check on the installed build.

## Boundaries

- An editor inside the app, a Markdown preview, or a different app per template. [paraphrase]
- Renaming or duplicating a template from the app. [inferred]
- Opening meeting notes (the All Recordings window) with the chosen app. [inferred]

## Decision Context

- **D1 · Templates stay Markdown files edited in an app the user picks; no editor is built into the app.** why: the owner picked option A on 2026-11-12, over Finder only and over an in-app editor, which would cost about two to three times the build for a plain text box without Markdown support · status: active [owner-stated 2026-11-12]
- **D2 · The name is asked in a "New Template…" window with a note on what happens; Edit becomes a split button with Open in <app>, Open With and Show in Finder, and the app remembers the chosen app.** why: the inline field is hard to see, and the default app may not be the editor the owner wants · status: active [owner-stated 2026-11-12]
- **D3 · The accepted mockup is the layout and the wording: boards 207·1 (section with the split button and the menu), 207·2 (New Template window), 207·3 (a name already used) and 207·4 (the app cannot open the file).** why: the owner accepted the boards on 2026-11-12 ("A: Mockups OK") · status: active [owner-ratified 2026-11-12]
- **D4 · This spec is built, tested, merged and installed in the session that wrote it, after the mockups are accepted.** why: the owner's pick "Spec + mockups, build here" on 2026-11-12 · status: active [owner-stated 2026-11-12]
- **A1 · One editor app for all templates, remembered by bundle identifier; choosing an app under Open With or Other… in any row changes it.** flip at: a different app per template · test: choosing an app under Open With makes the next Edit of another template open in it, also after a relaunch · status: active [agent-assumed 2026-11-12]
- **A2 · A remembered app that is gone or fails to open the file leads to Finder with the orange line, and a gone app is forgotten, instead of opening another app without asking.** flip at: open the default app instead · test: a remembered app the fake reports missing reveals the file, sets the "was not found" line and clears the setting · status: active [agent-assumed 2026-11-12]
- **A3 · Open With lists the apps macOS offers for the file, the default first with "(default)", the rest by name, each once, then "Other…".** flip at: a fixed list of known editors · test: the Open With list order · status: active [agent-assumed 2026-11-12]
- **A4 · An empty name disables Create without a red line; every other refused name shows the store's existing message in red.** flip at: show "Enter a name for the template." at once · test: the window's state for an empty and a duplicate name · status: active [agent-assumed 2026-11-12]
- **A5 · The orange line sits where today's red message sits, under the New Template… line, and clears on the next successful action.** flip at: an alert instead of a line · test: a failed open sets the line and the next successful open clears it · status: active [agent-assumed 2026-11-12]

Mockup gate: accepted by the owner on 2026-11-12. The boards are on a private design canvas, so this spec writes out their layout and wording; the example names in them ("Daily stand-up", "Board update", "TextEdit", "Visual Studio Code", "Typora") are examples.
