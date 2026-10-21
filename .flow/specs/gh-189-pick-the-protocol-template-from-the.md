# Pick the protocol template from the meeting title

## Conversation Evidence

> owner (session 2026-10-21, paraphrased): wants several report templates, to make protocols for existing meetings again with other templates, and to choose which template a meeting gets: a default, or rules with regular expressions that pick the template for new meetings automatically, so that for example daily meetings always get one specific report format.
> owner (session 2026-10-21, selected): "Every new meeting (Recommended)" for the question where the rules apply. The option read: starts without a window use the matched template, the two option windows open with it preselected, and a template picked by hand still wins.
> owner (session 2026-10-21, selected): "Two specs (Recommended)": the rules here, keeping the old protocol on regenerate in a sibling spec (#190).
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
- **Resolver:** one pure function from (meeting title, rule list, templates present, default template) to the chosen template plus what chose it: a rule (by position) or the default. Every consumer goes through it; nothing else matches titles against rules. [inferred]
- **Consumers:** (1) queue admission: a job without a template of its own gets the resolver's template for its meeting title, where it gets the default today; (2) the start dialog ("Record with Options…") and the Record Meeting window start their template choice from the resolver for their meeting's title; (3) the try-a-title field in Settings. [paraphrase]
- **Settings:** the rule list sits in the protocol templates section, where templates and the default are managed: a pattern field and a template picker per rule, add, delete, move up and down, and the try-a-title field. [inferred]

## Edge Cases & Constraints

- **Title source.** A detected meeting carries its meeting window's title only with the Screen Recording permission; otherwise its title is "<App> Call", and rules match that. An import carries its file name as title, a microphone-only recording its own title. Rules match whatever title the job carries when it enters the queue. [inferred]
- **Bad patterns.** A pattern that is empty or not a valid regular expression is refused while it is typed and never saved. A stored pattern that does not compile (written by another build) is skipped like a rule whose template is missing. [inferred]
- **Missing template.** A rule whose template file is gone is skipped, so the next rule or the default applies; Settings marks the rule. Putting the file back makes the rule work again. [inferred]
- **Hand-picked template wins.** A template chosen in an options window is the job's template even when a rule matches another one. [paraphrase]
- **Start dialog.** Its meeting title is known only once a source is selected. The preselected template follows the selected source until the user changes the template picker; from then on the user's choice stays. [inferred]
- **No rules.** With an empty rule list every path behaves exactly as today. [inferred]
- **Privacy.** Meeting titles and patterns are user text: log lines carry them only as private values. No window is added to the debug server's screenshot, tree or press allowlists. [inferred]
- **Both build variants.** The rules work the same in the Homebrew and the App Store build. [inferred]

## Acceptance Criteria

- **R1:** Settings lets the user add, edit, reorder and delete rules, each a title pattern and a template, and the list survives an app restart. Errors: an empty pattern or one that is not a valid regular expression is refused with an inline message and not saved; a rule whose template file no longer exists is shown as such and kept. [paraphrase]
- **R2:** For a meeting title the chosen template is that of the first rule, in list order, whose pattern matches somewhere in the title, ignoring case, and whose template exists; when no rule matches, the default template. Errors: a rule whose template is missing or whose stored pattern does not compile is skipped; an empty title gets the default. [paraphrase]
- **R3:** Every job that enters the queue without a template chosen by hand gets the template R2 picks for its meeting title, decided when it enters the queue. This covers a detected meeting answered without the options window, the immediate start, "Record Microphone Only", file imports, the automation API and a recovered recording. Errors: no error surface beyond R2; with no rules every such job gets the default, as today. [paraphrase]
- **R4:** The start dialog and the Record Meeting window open with the template R2 picks for their meeting's title selected and say which rule picked it, or that it is the default. In the start dialog the selection follows the selected source until the user changes the template. A template the user picks there is the job's template even when a rule matches another. Errors: no error surface beyond R2. [paraphrase]
- **R5:** Settings has a field to try a title: it shows the template that title would get and which rule matched, or that the default applies, and a note that a detected meeting has its real window title only with the Screen Recording permission and is called "<App> Call" otherwise. Errors: an empty field shows no result. [inferred]

## Boundaries

- A rule that picks a profile (gh-6) instead of a template, and how a rule ranks against a profile's own template: decided in gh-6. [inferred]
- Rules on anything but the meeting title (app, participants, calendar). [inferred]
- Rules delivered from a central URL (#69). [inferred]
- The Regenerate Protocol sheet keeps opening on the default template. [inferred]

## Decision Context

- **D1 · The rules apply to every new meeting: starts without a window get the matched template, the start dialog and the Record Meeting window open with it selected, and a template picked by hand still wins.** why: otherwise a start through a window quietly uses the default · status: active [owner-ratified 2026-10-21]
- **D2 · A rule's pattern is a regular expression on the meeting title.** why: the owner asked for rules with regular expressions · status: active [owner-stated 2026-10-21]
- **D3 · The rules and keeping the old protocol on regenerate are two specs (this one and #190).** why: each ships on its own · status: active [owner-ratified 2026-10-21]
- **A1 · Patterns match case-insensitively anywhere in the title, and the first rule in list order wins.** flip at: the owner wants case-sensitive or whole-title matching, or the most specific rule to win · test: the pattern "daily" matches "Team Daily Stand-up" · status: active [agent-assumed 2026-10-21]
- **A2 · Rules match the title only, not the app or the participants.** flip at: a recurring meeting cannot be told apart by its title · test: a rule has no app field · status: active [agent-assumed 2026-10-21]
- **A3 · The rule list is stored with the app's settings, per build like the default template, not as a file in the templates folder.** flip at: rules should come from a central URL (#69) or be shared by the dev and the release build · test: a rule added in one build does not show in the other · status: active [agent-assumed 2026-10-21]
- **A4 · A rule whose template is missing, or whose stored pattern does not compile, is skipped; the job gets no warning.** flip at: the owner wants a warning on the job · test: removing a rule's template file makes the next rule or the default apply · status: active [agent-assumed 2026-10-21]
- **A5 · The template is decided when the job enters the queue, from the title the job carries then.** flip at: titles change during meetings and the owner wants the latest one · test: a detected meeting's job gets the template for the title in its protocol's file name · status: active [agent-inferred 2026-10-21]
- **A6 · The Regenerate Protocol sheet keeps opening on the default template.** flip at: the owner wants the rule's template preselected there too · test: the regenerate sheet for a meeting whose title matches a rule opens on the default · status: active [agent-assumed 2026-10-21]
- **A7 · Settings gets a try-a-title field (R5).** flip at: the owner finds it unnecessary · test: typing a title shows its template and the matching rule · status: active [agent-assumed 2026-10-21]

Mockup gate: no accepted mockup yet for the rule list in Settings and the two windows; plan and work wait for it (owner rule 2026-10-14: screens are drawn and accepted before code).

Related: #2 (templates, shipped), #190 (sibling spec), gh-6 (profiles), #155 (shared options-window code), #69 (templates from a URL). Upstream check 2026-10-21: the original has no open issue or pull request about protocol templates or template rules; templates exist only in this fork.
