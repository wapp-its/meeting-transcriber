---
satisfies: [R1, R2, R3, R4, R5, R6, R7]
---
# gh-128-fork-ci-runs-once-before-the-merge-not.1 Implement Fork CI runs once before the merge, not on every push

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
A push to a fork PR starts no CI any more. `wapp-fork-ci.yml` is now a manual request (`-f pr=<n>`): `fork_ci.py request` judges the PR head against commits whose ci.yml run (workflow_dispatch or push only) passed, posts `success` when only `.flow/`, Markdown or `docs/` differ, and otherwise starts ci.yml and posts `pending`. `wapp-fork-ci-result.yml` (workflow_run on CI) runs `fork_ci.py result`: success, one retry on a first failure (failed jobs, then a full rerun), failure on the second; nothing for superseded runs, stale attempts, pull_request runs or other workflows named CI; the culprit comes from a failed job or the cancel-on-failure annotation. The fork rules (`.claude/rules/wapp-fork.md`) describe when to request and that a merge needs `success` on the current head.

Tests: 37 local tests (throwaway git repos + stand-in gh), written first and seen failing; `actionlint .github/workflows/wapp-fork-ci*.yml` clean; read-only run against real fork data (plan PR #114 skips, feature PRs run, a real culprit annotation is found).

stage: impl-review - ran [a8368667..65c8c8f5] round 1 NEEDS_WORK (5 findings, all fixed: pull_request runs as evidence, workflow identity, superseded success, stale attempt, annotation paging), validator kept 5/5, re-review SHIP (model: gpt-6-astra)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: a8368667d964b97311ad019c0eaa29686c0bea57, 65c8c8f56a57ac6231263965bb7627e5098322e5
- Tests: python3 -m unittest discover -s .github/workflows/wapp-fork-ci -p test_*.py (37 OK); actionlint .github/workflows/wapp-fork-ci*.yml (clean)
- PRs: