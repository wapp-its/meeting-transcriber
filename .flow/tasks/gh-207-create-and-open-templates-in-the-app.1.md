---
satisfies: [R1, R2, R3, R4, R5]
---
# gh-207-create-and-open-templates-in-the-app.1 Implement Create and open templates in the app you choose

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
Settings > Output > Meeting Notes Templates now creates a template in a "New Template" window and opens templates through an Edit split button (Open in <app>, Open With, Show in Finder) in the app chosen last, remembered by bundle identifier in AppSettings, with Finder and an orange line as the fallback when that app fails, is gone or no app opens Markdown files. Every open, reveal and app picker goes through the injected TemplateOpener; tests use a fake and never launch an app, show a panel or reveal a real file.

stage: impl-review - ran [..2026-11-12T16:35:22Z] - codex gpt-6-astra xhigh, 1 round (3 draws, all SHIP), verdict SHIP; the contracts draw's two P2 findings were fixed after the verdict in 4ef3c156 and 262fd5a1 (focused tests, both variants), not re-reviewed

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

baseline: none (the spec defines no Quick commands)

Tests (focused classes, both variants, on the final head):
- Homebrew: `CFFIXED_USER_HOME=<scratch> swift test --filter 'TemplateEditorTests|TemplateOpenerTests|ProtocolTemplatesSettingsTests|ProtocolTemplatesNewTemplateTests|ProtocolTemplatesOpeningTests|AppSettingsTemplateEditorTests|AppSettingsTests|SettingsViewTests|TemplateRulesSettingsTests|TemplateRulesLayoutTests|OutputSettingsViewTests'`: 277 tests, 0 failures
- App Store: the same with `-Xswiftc -DAPPSTORE`: 263 tests, 0 failures
- `./scripts/lint.sh` (pinned SwiftFormat 0.64.5, SwiftLint 0.65.1): 0 violations, 0 files to format
- Red checks: the Open With order, remembering the app chosen under Open With or Other..., forgetting a missing app, the empty-name rule, the missing-app wording and the Show in Finder retry each failed against a mutated or earlier source before passing
- TemplateOpenerTests only query LaunchServices (TextEdit by bundle id, an unknown id, the Markdown app list); they never open, reveal or show a panel

Decisions:
- ASSUMED: when Finder cannot show the file either, the orange line reads "<reason>, and Finder could not show it either: <error>". Alternatives: B - a red line with Finder's error only. Flip at TemplateEditor.swift:TemplateOpenFailure.notShown. Test: TemplateEditorTests.testEachReasonHasItsLineWhetherOrNotFinderShowsTheFile
- ASSUMED: with no app for Markdown files, the help text and the window's note say the file is shown in Finder ("as no app is set to open Markdown files. To use an app, ..."). Alternatives: B - keep the app sentence and add a separate Finder sentence. Flip at TemplateEditor.swift:TemplateEditor.helpText/newTemplateNote. Test: TemplateEditorTests.testWithoutAnAppTheHelpTextAndTheNoteSayTheFileIsShownInFinder
- ASSUMED: a remembered app that is gone is named by its bundle identifier in the "was not found" line and in the Finder reason of the help text and note; the Edit menu then has no "Open in" item. Alternatives: B - "The app you chose was not found". Flip at TemplateEditor.swift:TemplateEditor.finderReason and TemplateOpenFailure.notFound. Test: TemplateEditorTests.testARememberedAppThatIsGoneIsMissing
- ASSUMED: the note for an empty name says "Creates a Markdown file ...". Alternatives: B - hide the note until a name is typed. Flip at TemplateEditor.newTemplateNote. Test: TemplateEditorTests.testWithoutAnAppTheHelpTextAndTheNoteSayTheFileIsShownInFinder
- ASSUMED: Open With and Other... remember the app before the open's outcome is known, so a failed open keeps the choice. Alternatives: B - remember it only after a successful open. Flip at ProtocolTemplatesSettingsView.swift:ProtocolTemplatesModel.openWith. Test: ProtocolTemplatesOpeningTests.testAnAppThatCannotOpenTheTemplateLeadsToFinderUntilTheNextOpenWorks
- DECIDED: a failed Show in Finder shows Finder's error in red, like a failed delete, and a later successful one clears it (existing error-line pattern).
- DECIDED: an app picked under Other... without a bundle identifier is ignored like a cancelled panel, since the editor app is remembered by bundle identifier.
- DECIDED: the Open With list and the editor app are read live each time the section is drawn (the LaunchServices lookup measured about 7 ms), not cached.
- DECIDED: the orange line shares the one notice slot under New Template... with the red errors (A5).

Feature map: none exists in this repo, so no route to report. No logging was added.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 635ca99fc4b4d0a8700c05b2cba46c6df5611845, 4ef3c1566a3351679846c0cd1d475f832a99c87f, 262fd5a147dace4a2dda0474d6c83a12f57bdb5f
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --filter 'TemplateEditorTests|TemplateOpenerTests|ProtocolTemplatesSettingsTests|ProtocolTemplatesNewTemplateTests|ProtocolTemplatesOpeningTests|AppSettingsTemplateEditorTests|AppSettingsTests|SettingsViewTests|TemplateRulesSettingsTests|TemplateRulesLayoutTests|OutputSettingsViewTests' (Homebrew: 277 tests, 0 failures), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test -Xswiftc -DAPPSTORE --filter '<same classes>' (App Store: 263 tests, 0 failures), ./scripts/lint.sh (0 violations)
- PRs: