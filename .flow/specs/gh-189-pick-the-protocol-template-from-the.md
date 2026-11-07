# Pick the protocol template from the meeting title

## Conversation Evidence

> owner (session 2026-10-21, paraphrased): wants several report templates, to make protocols for existing meetings again with other templates, and to choose which template a meeting gets: a default, or rules with regular expressions that pick the template for new meetings automatically, so that for example daily meetings always get one specific report format.
> owner (session 2026-10-21, selected): "Every new meeting (Recommended)" for the question where the rules apply. The option read: starts without a window use the matched template, the two option windows open with it preselected, and a template picked by hand still wins.
> owner (session 2026-10-21, selected): "Two specs (Recommended)": the rules here, keeping the old protocol on regenerate in a sibling spec (#190).
> owner (selected, 2026-10-28): "A: Mockups OK (Recommended)", the seven-board mockup of this spec and #190. Four boards belong here: Settings with the Template Rules group, the start dialog, the Record Meeting window, and the line under Template case by case.
> owner (2026-10-30): "MOCKUP OK, all ok", which also keeps this spec's assumptions A1 to A7 as written.
> issue #2 (closed, shipped): several templates in a folder, one of them the default, a template and background info chosen per recording in an options window, and "Regenerate Protocol…".
> issue #155 (open): the three options windows repeat the same template-choice code by hand.
> issue #6, spec gh-6 (open): profiles chosen at the start of a recording; a choice per detected app is a follow-up there.

## Goal & Context

Templates and a default template exist (#2). A recording that starts without an options window gets the default, and an options window opens on the default. A meeting that recurs, such as a daily stand-up, needs the same non-default template every time, so today the user picks it by hand at every start or the meeting gets the default format. Rules map a meeting title to a template, so a recurring meeting gets its format without a click, and a window start shows that template instead of the default.

Today the default is stamped onto a job without a template of its own when the queue admits it, and each options window reads the default once when it opens. Both are the points where the rules take over.

<!-- Source: 0% user / 60% [paraphrase] / 40% [inferred] -->

## Architecture & Data Models

- **Rule:** a pattern and a template. The pattern is a regular expression, matched case-insensitively anywhere in the meeting title. The template is stored in the same form the default template uses, so a template name this build does not know reads as missing, not as an error. [paraphrase]
- **Rule list:** ordered, kept with the app's settings next to the default template, survives a restart. [inferred]
- **Resolver:** one pure function from (meeting title, rule list, templates present, default template) to the chosen template, what chose it (a rule by position, or the default) and the positions of the rules that ran out of time on this title, also when a later rule matched or the default won. Every consumer goes through it; nothing else matches titles against rules. [inferred]
- **Consumers:** (1) queue admission: a job without a template of its own gets the resolver's template for its meeting title, where it gets the default today; (2) the start dialog ("Record with Options…") and the Record Meeting window start their template choice from the resolver for their meeting's title; (3) the try-a-title field in Settings. [paraphrase]
- **Settings (accepted mockup):** in Settings → Output, a group "Template Rules" directly under the group "Meeting Notes Templates" (the mockup's "Protocol Templates", renamed by the app since), which stays as it is. From top to bottom: [paraphrase]
  - the caption "A new meeting whose title matches a pattern gets that rule's template. Rules are tried from the top, and the first match wins. When no rule matches, the meeting gets the default template. A pattern is a regular expression and ignores upper and lower case: “daily” matches “Team Daily”.";
  - the column headings "Meeting title contains" and "Template";
  - one row per rule: its position number, the pattern field in a fixed-width font, a template picker with the same choices as "Default template", and the buttons move up, move down and delete (move up disabled on the first row, move down on the last);
  - the button "Add Rule";
  - below a divider, the field "Try a title", its result line, and the note "A detected meeting has its real window title only when Meeting Transcriber has the Screen Recording permission. Without it, the title is the app's name followed by “Call”, for example “Microsoft Teams Call”. An imported file's title is its file name."
- **Marks on a rule row (accepted mockup):** a missing template shows in the picker as "<name> (missing)" with an orange border and the warning line "The template “<name>” is no longer in the templates folder, so this rule is skipped. It works again when the file is back." A pattern that is not valid gets a red border and the red line "Not a valid pattern: <reason>. The rule is saved once the pattern is valid.", as in the mockup's "a “(” is not closed". The system's error names no reason (measured), so the app names one only for an unclosed “(” or “[”; any other invalid pattern reads "Not a valid pattern. The rule is saved once the pattern is valid." An empty pattern reads "Enter a pattern. The rule is saved once the pattern is valid." [paraphrase]
- **Try-a-title result (accepted mockup):** a match reads "Gets **<template>**, from rule <n> (<pattern>)."; no match reads "Gets the default template, **<template>**: no rule matches." A rule that ran out of time adds "Rule <n> took too long on this title and is skipped." before that result, one sentence per such rule. [paraphrase]
- **The line under Template (accepted mockup):** the start dialog and the Record Meeting window show one small grey line under the template picker: [paraphrase]
  - a rule matches: "From rule 1 (daily|stand-?up), matching the title “Team Daily”.";
  - no rule matches: "Default template: no rule matches the title “Microsoft Teams Call”.";
  - start dialog with nothing selected yet: "Default template until you choose what to record.";
  - the user picked another template: "Chosen by you. This recording uses it, whatever the rules say.";
  - the rule list is empty: no line, as today.
- **Window sizes:** both windows keep their width of 440 points and grow by the height of the line, so nothing is clipped. [inferred]

## Edge Cases & Constraints

- **Title source.** Rules match the title the job carries when it enters the queue. A detected meeting carries its meeting window's title, without the app's own suffix such as " | Microsoft Teams", only with the Screen Recording permission; otherwise its title is "<App> Call". A recording from the start dialog carries the typed title, else the app's name; a microphone-only recording "Microphone Recording"; a single imported file its name without the extension; a paired import (app and microphone tracks) the title in its sidecar file, else the shared part of the file names; a recovered recording "Recovered Recording (<stem>)". The note in Settings names the common cases only. [inferred]
- **Bad patterns.** A pattern that is empty or not a valid regular expression is refused while it is typed and never saved. While a saved rule's field holds such a text, the rule's last valid pattern stays in force; a new rule has no effect until its pattern is valid. A stored pattern that does not compile (written by another build) is skipped like a rule whose template is missing. [inferred]
- **Slow patterns.** A user's pattern can run away on some titles, and the template is chosen on the app's main thread: queue admission and both windows run there and choose synchronously, so there is no late result to reconcile. One rule's check stops after about a twentieth of a second, and all rules together for one title after about a quarter of a second. A stopped rule and any rule not reached count as no match, so the next rule or the default applies and no job is held back. Measured with the system's regular expressions: a run-away pattern stops within a millisecond of its limit, and an ordinary check takes about 3 microseconds, so the limits are reached only by a broken pattern. A batch import chooses per file, so it can hold the app for up to a quarter of a second per file, only when a pattern runs away on every one of those titles; that is accepted for a broken pattern on a deliberate import, and Settings shows the rule's message for any title tried. [inferred]
- **Missing template.** A rule whose template file is gone is skipped, so the next rule or the default applies; Settings marks the rule. Putting the file back makes the rule work again. [inferred]
- **Hand-picked template wins.** A template chosen in an options window is the job's template even when a rule matches another one. [paraphrase]
- **Start dialog.** Its title is known only once a source is selected. The selected template and the line follow the title the recording would get, also while the user types it, until the user changes the template picker; from then on the user's choice stays. [paraphrase]
- **Window starts keep what they showed.** Record and Start Recording hand the template the window shows to the job, so the queue does not choose again for a title that changed since. [inferred]
- **Record Meeting window.** Its question names the app only, so the prompt carries the meeting's title as well, the same one the job would get. [inferred]
- **Record-only mode.** No job enters the queue, so no rule applies; the options form stays dimmed as today. [inferred]
- **No rules.** With an empty rule list every path behaves exactly as today. [inferred]
- **Privacy.** Meeting titles and patterns are user text: log lines carry them only as private values, and accessibility identifiers of rule rows use the row's position, never its text. No window is added to the debug server's screenshot, tree or press allowlists. [inferred]
- **Both build variants.** The rules work the same in the Homebrew and the App Store build. [inferred]

## Acceptance Criteria

- **R1:** Settings → Output has the group "Template Rules" of the accepted mockup, where the user adds, edits, reorders and deletes rules, each a title pattern and a template, and the list survives an app restart. Errors: an empty pattern or one that is not a valid regular expression is refused with the inline message above and not saved; a rule whose template file no longer exists is shown with the mockup's warning and kept. [paraphrase]
- **R2:** For a meeting title the chosen template is that of the first rule, in list order, whose pattern matches somewhere in the title, ignoring case, and whose template exists; when no rule matches, the default template. Errors: a rule whose template is missing, whose stored pattern does not compile or whose check on this title runs out of time is skipped; an empty title gets the default. [paraphrase]
- **R3:** Every job that enters the queue without a template chosen by hand gets the template R2 picks for its meeting title, decided when it enters the queue. This covers a detected meeting answered without the options window, the immediate start, "Record Microphone Only", file imports, the automation API and a recovered recording. Errors: no error surface beyond R2; with no rules every such job gets the default, as today. [paraphrase]
- **R4:** The start dialog and the Record Meeting window open with the template R2 picks for their meeting's title selected, and the line under the template picker says in the accepted wording which rule picked it, that no rule matches, or, in the start dialog with nothing selected yet, that the default applies. In the start dialog the selection and the line follow the title the recording would get until the user changes the template; from then on the line reads "Chosen by you. This recording uses it, whatever the rules say." and that template is the job's template even when a rule matches another. Errors: no error surface beyond R2; with no rules no line is shown. [paraphrase]
- **R5:** The field "Try a title" in Settings shows the template that title would get and which rule matched, or that the default applies, in the accepted wording, and the note under it says that a detected meeting has its real window title only with the Screen Recording permission and is called "<App> Call" otherwise. Errors: an empty field shows no result. [paraphrase]

## Validation

Test first, from the criteria, in this order, at the cheapest layer that can fail:

1. **Resolver (pure logic):** first match wins, case is ignored, a match anywhere counts, a missing template and a stored pattern that does not compile are skipped, an empty title gets the default, a rule that runs away and twenty rules that run away return within the limits and report their positions, and a later rule still applies after a stopped one.
2. **Rule list:** survives a save and a reload; a refused pattern is never saved, a saved rule keeps its last valid pattern while its field holds an invalid text, and a template name this build does not know comes back unchanged.
3. **Queue admission:** a job without a template gets the rule's template and a job with its own keeps it, for an ordinary enqueue, a single import, a paired import whose sidecar title differs from its file names (the rule follows the sidecar title) and a recovered recording; with no rules every job gets the default.
4. **Windows (one wiring test per control, as the repository's GUI rules ask):** the start dialog follows the selected source and the typed title until the template is changed by hand and stays there, the Record Meeting window opens on the rule's template for the title it was handed, Record and Start Recording hand on what the window shows, and each of the five cases shows its accepted line. Settings: add, edit, reorder, delete and the try-a-title result in each wording.
5. **Privacy:** a test that the rule rows' accessibility identifiers carry only positions; a read of the log lines for private values.
6. **Both build variants:** the suite runs for the Homebrew and the App Store build, as CI does.
7. **Look:** a dev-only snapshot of both windows with the longest line under Template, and of Settings with a missing template and an invalid pattern, to check that the lines wrap and the windows grow without clipping. How it looks stays the owner's check on the installed build.

## Boundaries

- A rule that picks a profile (gh-6) instead of a template, and how a rule ranks against a profile's own template: decided in gh-6. [inferred]
- Rules on anything but the meeting title (app, participants, calendar). [inferred]
- Rules delivered from a central URL (#69). [inferred]
- The Regenerate Notes sheet keeps opening on the default template and shows no line under Template. [inferred]

## Decision Context

- **D1 · The rules apply to every new meeting: starts without a window get the matched template, the start dialog and the Record Meeting window open with it selected, and a template picked by hand still wins.** why: otherwise a start through a window quietly uses the default · status: active [owner-ratified 2026-10-21]
- **D2 · A rule's pattern is a regular expression on the meeting title.** why: the owner asked for rules with regular expressions · status: active [owner-stated 2026-10-21]
- **D3 · The rules and keeping the old protocol on regenerate are two specs (this one and #190).** why: each ships on its own · status: active [owner-ratified 2026-10-21]
- **D4 · The accepted mockup is the layout and the wording: the group "Template Rules" under "Protocol Templates" in Settings → Output, and one line under Template in the start dialog and the Record Meeting window, with five cases.** why: the owner accepted the boards on 2026-10-28 ("Mockups OK") · status: active [owner-ratified 2026-10-28]
- **D5 · In the start dialog the rules also follow the title the user types, not only the selected source.** why: the mockup shows a typed title picking the template, and the reply that showed it named this detail; the owner accepted it · status: active [owner-ratified 2026-10-28]
- **A1 · Patterns match case-insensitively anywhere in the title, and the first rule in list order wins.** flip at: the owner wants case-sensitive or whole-title matching, or the most specific rule to win · test: the pattern "daily" matches "Team Daily Stand-up" · status: active [agent-assumed 2026-10-21]
- **A2 · Rules match the title only, not the app or the participants.** flip at: a recurring meeting cannot be told apart by its title · test: a rule has no app field · status: active [agent-assumed 2026-10-21]
- **A3 · The rule list is stored with the app's settings, per build like the default template, not as a file in the templates folder.** flip at: rules should come from a central URL (#69) or be shared by the dev and the release build · test: a rule added in one build does not show in the other · status: active [agent-assumed 2026-10-21]
- **A4 · A rule whose template is missing, or whose stored pattern does not compile, is skipped; the job gets no warning.** flip at: the owner wants a warning on the job · test: removing a rule's template file makes the next rule or the default apply · status: active [agent-assumed 2026-10-21]
- **A5 · The template is decided when the job enters the queue, from the title the job carries then.** flip at: titles change during meetings and the owner wants the latest one · test: a detected meeting's job gets the template for the title in its protocol's file name · status: active [agent-inferred 2026-10-21]
- **A6 · The Regenerate Protocol sheet keeps opening on the default template.** flip at: the owner wants the rule's template preselected there too · test: the regenerate sheet for a meeting whose title matches a rule opens on the default · status: active [agent-assumed 2026-10-21]
- **A7 · Settings gets a try-a-title field (R5).** flip at: the owner finds it unnecessary · test: typing a title shows its template and the matching rule · status: active [agent-assumed 2026-10-21]
- **A8 · One rule's check stops after about a twentieth of a second and one title's rules together after about a quarter of a second, then count as no match, because a badly built pattern could otherwise freeze the app while a recording runs; a batch import may wait that long per file when a pattern runs away on every title.** flip at: the time limits in the resolver's matching · test: twenty run-away rules return within the limit and the rule list's default applies · alternatives: B — no limit, a slow pattern is the user's own problem · status: active [agent-assumed 2026-11-06]
- **A9 · A new rule starts on the current default template with an empty pattern, and is saved only once its pattern is valid; a row that never got a valid pattern is gone the next time Settings opens.** alternatives: B — a new rule starts on the first template in the folder · flip at: the owner expects a half-typed rule to be kept, or a different starting template · test: Add Rule with the default "Board" shows a row on "Board" and saves nothing until its pattern is valid · status: active [agent-assumed 2026-11-07]
- **A10 · Rules that the quarter-second limit for one title never reached are reported like a rule that ran out of time: "Try a title" names each of them as skipped.** alternatives: B — name only the rule that was stopped and leave the unreached ones unnamed · flip at: the owner finds the list of skipped rules confusing · test: twenty run-away rules report positions 1 to 20 and the default applies · status: active [agent-assumed 2026-11-07]

Mockup gate: accepted by the owner on 2026-10-28. The boards are on a private design canvas, so this spec writes out their layout and wording; the example names in them (rule 1, "Team Daily") are examples.

Related: #2 (templates, shipped), #190 (sibling spec), gh-6 (profiles), #155 (shared options-window code), #69 (templates from a URL). Upstream check 2026-10-21: the original has no open issue or pull request about protocol templates or template rules; templates exist only in this fork.

FIT: GO · 2026-11-06 · base c9951a52 · engine flow-next 9.6.0 · the merged Notion export reads the same per-job template field a rule writes, nothing upstream chooses a template by title, and only screen names moved

FIT: GO · 2026-11-07 · base 1c5088f2 · engine flow-next 9.6.0 · gh-97 added a Recordings group to Settings → Output and file records at queue admission without touching the per-job template field, and today's upstream merge touched only the naming window
