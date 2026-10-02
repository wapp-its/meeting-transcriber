# Settings view type-check under the CI limit

## Conversation Evidence

> user (turn 1): "/flow-next:flow https://github.com/wapp-its/meeting-transcriber/issues/17"
> user (issue #17, Problem): "Die App wird mit einer Zeitgrenze für den Compiler gebaut: Ein Funktionsrumpf darf beim Typprüfen höchstens 300 ms brauchen, sonst ist es ein Fehler"
> user (issue #17, Problem): "Der `body` von `TranscriptionSettingsView` […] liegt auf den macOS-Runnern von GitHub genau an dieser Grenze"
> user (issue #17, Problem): "PR #14, 1. Lauf | 331 ms | rot" · "PR #14, 2. Lauf | < 300 ms | grün" · "PR #16, beide Versuche | 302 ms | rot"
> user (issue #17, Problem): "Folge im Fork: die CI für Fork-PRs (`wapp-fork-ci.yml`) ist für jeden PR zufällig rot, und der Upstream-Sync kann am Build scheitern."
> user (issue #17, Wunsch): "Den `body` in kleinere Teil-Views oder `@ViewBuilder`-Eigenschaften aufteilen, so dass er deutlich unter 300 ms bleibt (Ziel: unter 150 ms auf dem Runner). Reines Refactoring, keine sichtbare Änderung."
> user (issue #17, Hinweise): "`feat/custom-whisperkit-model` (PR #759 im Original) ändert dieselbe Datei und vergrössert den `body` zusätzlich; der Fix sollte darauf abgestimmt werden (zuerst einspielen, #759-Branch danach darauf bringen)."
> user (issue #17, Hinweise): "Messbar lokal mit `swift build -Xswiftc -Xfrontend -Xswiftc -debug-time-function-bodies`."
> user (issue #17, Hinweise): "Hilft auch dem Original; Einreichung über `submit.sh` nach Freigabe."
> user (issue #17, Abnahme): "Drei CI-Läufe in Folge auf einem Fork-PR grün, ohne Wiederholung."
> user (issue #17, Abnahme): "Die Einstellungen sehen aus und verhalten sich wie vorher (bestehende ViewInspector-Tests grün)."
> user (issue #17): "Kandidat fürs Original (eigener `fix/…`-Branch)."

## Goal & Context

<!-- Source: 70% user / 20% [paraphrase] / 10% [inferred] -->

The app is compiled with a hard per-function type-check budget: any function body that takes the
compiler more than 300 ms to type-check is a build error. The `body` of the Transcription settings
screen (`TranscriptionSettingsView`) sits right at that limit on GitHub's macOS runners, so CI turns
red at random on commits that touch no Swift code at all. In the fork that makes every fork PR's CI
a coin toss and can break the automatic upstream sync's build.

The fix is a pure refactoring: split the `body` into smaller sub-views or `@ViewBuilder` properties
so it stays well clear of the limit, with nothing visible changing for the user. It helps the
original project too and is a candidate for submission there once the owner releases it.

## Architecture & Data Models

The screen is one SwiftUI view with two sections ("Transcription" and "Live transcription (PoC)").
The live-transcription section and its sub-controls were already hoisted into named properties for
this same reason; the "Transcription" section (engine and model pickers, language pickers,
custom-vocabulary field and validation, the WhisperKit vocabulary-prompt toggle and notes, the
terminology editor, and the engine status row) is still built inline in `body`. Splitting that
section into named pieces moves their type-check cost out of `body`, since each named property is
type-checked as its own function body. [paraphrase]

The split should give the WhisperKit model picker its own piece, so the custom-model change
(`feat/custom-whisperkit-model`), which adds a "Custom model…" picker entry and a block of fields
right there, lands in that piece rather than growing `body` again. [inferred]

## Edge Cases & Constraints

- **The runner is the only real measurement surface.** Measured on 2026-10-02: the unchanged `body`
  read 142.8 ms on a green runner run and 302–331 ms on red ones, so runner speed alone swings the
  figure by more than 2×. Locally (Xcode 27.0) the same `body` reads 37–39 ms, while the runners use
  Xcode 26.6, and the ranking of slow bodies differs between the two compilers (locally `AppState.init`
  is the slowest at 90 ms; on the runner it is not in the top ten). A local reading shows the
  direction of a change, not whether it clears the runner target. [inferred]
- The analyze lane of the upstream CI already prints the slowest bodies of every run ("Report slowest
  type-checks"), and a body over the limit is reported as an error in both the analyze and the test
  lanes; these are where the runner figure is read. [inferred]
- The fork's CI wrapper retries a failed CI run once and leaves a warning on the PR when it did;
  "without a retry" means that warning is absent. [inferred]

## Acceptance Criteria

- **R1:** The Transcription settings view's `body` type-checks in under 150 ms on GitHub's macOS
  runner, read from the analyze lane's slowest-bodies report of the PR's CI runs, including any slow
  run (today's slow runs read 302–331 ms). No body the change creates in this view exceeds that
  figure either. Errors: a run that reports any body of this view at or over 300 ms fails this
  criterion outright; a run whose report is missing does not count towards it. [paraphrase]
- **R2:** The settings look and behave as before: the same controls in the same order, with the same
  labels, help texts, accessibility identifiers, enabled and disabled states and actions, in both
  sections and for both engines; the existing ViewInspector and settings tests pass without any test
  being edited, weakened or removed. No error surface beyond the screen's existing behaviour. [paraphrase]
- **R3:** Three CI runs in a row on the fork PR are green without a retry. Errors: a run that needed
  the fork CI's automatic retry, or a red run, resets the count. [paraphrase]
- **R4:** The custom-model branch can be brought onto the fix with its additions landing outside
  `body`, and the combined `body` still meets R1's bound. Verified on a local trial merge that is not
  pushed. Errors: a conflict that can only be resolved by putting the custom-model controls back
  inline in `body` fails this criterion. [inferred]

## Boundaries

- Pure refactoring, no visible change. [paraphrase]
- The 300 ms limit, the warnings-as-errors setting and the fork CI's retry stay as they are; this
  change makes the view fit the limit rather than moving the limit. [inferred]
- Other slow bodies elsewhere in the app are not part of this change. [inferred]
- Pushing the rebased custom-model branch (the head of PR #759 in the original) and submitting this
  fix to the original through `submit.sh` both wait for the owner's release; this spec only prepares
  them. [paraphrase]

## Decision Context

### Motivation

Fork PRs and the upstream sync fail at random on unchanged code, which hides real failures and
costs a retry per PR. The user's measurements (331 ms, 302 ms, under 300 ms on the same code) and the
second-run green show the cause is runner speed against a fixed limit, not a code defect.

Splitting `body` was chosen over raising the limit or disabling the check because the limit is the
original project's deliberate guard, and a submission to the original only has a chance if it keeps
that guard. The earlier hoist of the live-transcription section shows the original already handles
this view the same way. [inferred]

The target is read on the runner and applies to slow runs too: the green run already measured
142.8 ms, so a target that only the fast runs meet would change nothing. [inferred]
