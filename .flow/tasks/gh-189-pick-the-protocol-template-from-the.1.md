---
satisfies: [R1, R2, R3, R4, R5]
---
# gh-189-pick-the-protocol-template-from-the.1 Implement Pick the protocol template from the meeting title

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
Template rules pick a new meeting's protocol template from its title.

- Resolver (`ProtocolTemplateRules`): first matching rule in list order, case-insensitive, anywhere in the title; a missing template or an uncompiled pattern is skipped; about 0.05 s per rule and 0.25 s per title through `NSRegularExpression`'s progress callback, stopped and unreached rules reported.
- Rules are stored in `AppSettings.protocolTemplateRules` (survive a restart); queue admission (`stampTranscriptOutputOptions`) stamps the rule's template on every job without its own, so detected meetings, manual starts, imports (single and paired, by sidecar title), the automation API and recovered recordings follow the rules; a hand-picked template wins.
- Start dialog and Record Meeting window preselect the rule's template and show the line under Template in the five accepted wordings; the start dialog follows source and typed title until a hand pick; the consent question carries the cleaned meeting title; both windows keep width 440 and grow by the line. Regenerate sheet unchanged (no line).
- Settings → Output → Template Rules: caption, headings, rows (pattern, template picker, move up/down, delete), Add Rule, invalid-pattern and missing-template messages, "Try a title" with its result and note; identifiers by row position only.
- Docs: docs/architecture-macos.md updated in place.

Verification: full suite both variants via scripts/ci/test-shards.sh (Homebrew 6014/6014, App Store 5373/5373, 0 failures), lint clean with the pinned tools, clean xcodebuild build-for-testing plus `swiftlint analyze --strict` 0 violations, all 30 scripts/tests/test_*.sh ok, dev-only snapshots of both windows and Settings recorded and inspected (no clipping).

ASSUMED: A9 — a new rule starts on the current default template and is saved only once its pattern is valid; a row never valid is gone when Settings reopens.
ASSUMED: A10 — rules the per-title limit never reached are named as skipped in "Try a title", like a rule that ran out of time.

stage: impl-review - ran [codex:gpt-6-astra:xhigh, three draws correctness/contracts/integration, SHIP, 0 findings]

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 0117b66d15bff76a09015930462db4e1c8885f41, 88a4485a12ae176d5b9a316515f0fedd02d57245
- Tests: cd app/MeetingTranscriber && swift build --build-tests [-Xswiftc -DAPPSTORE] && ../../scripts/ci/test-shards.sh run --shards 3 --skip ModelPreloadTests (Homebrew 6014/6014, App Store 5373/5373)
- PRs: