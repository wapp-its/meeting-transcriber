# Fork CI runs once before the merge, not on every push

## Conversation Evidence

> user (turn 1): "Can we restrict the run trigger so that normal pushs dont trigger it, or how can we optimize it to avoid being disabled again?"
> user (turn 2, selected): "C — Both (Recommended)"
> user (turn 3): "Tell me when its merged o I can enable actions again"

Tracker issue #128 (body: usage 2026-10-02 to 10-08, causes, proposal) and the owner-decision comment of 2026-10-14 (https://github.com/wapp-its/meeting-transcriber/issues/128#issuecomment-6165887690) are the written record of option C and its safety points.

## Goal & Context

GitHub paused every workflow in the fork on 2026-10-08 "due to the scale of GitHub Actions usage" [paraphrase]. Since then fork PRs get no CI and `wapp/main` gets no upstream changes. The owner re-enables Actions once this change is merged, and the usage must drop so that GitHub is less likely to pause the fork again. GitHub publishes no threshold, so no change guarantees it [paraphrase].

Measured 2026-10-02 to 10-08 [paraphrase]: 67 `ci.yml` runs on 31 branches, about 58 macOS job-minutes each, plus 61 waiting jobs that held an ubuntu runner for 19 h in total. Classified by what changed since the previous run on the same branch: app code 45 % of the run time, only `.flow/`, Markdown or `docs/` 33 %, nothing at all 9 %, a merge of `wapp/main` into the PR 14 %. 24 runs were cancelled midway by a newer push.

The owner picked option C over A (only skip pushes without code changes, the issue's original proposal) and B (only run CI on request before the merge) [paraphrase]: CI runs once per PR, right before the merge, on the commit that gets merged, and that run is skipped when no code changed since a run that passed.

## Architecture & Data Models

Three parts, all fork-only [inferred]:

- **Request.** A manual start of the fork's CI workflow, naming the PR. It reads the PR's current head, decides between "skip" and "run", posts the commit status and, for "run", starts the original's `ci.yml` on the PR branch. It holds no runner after that.
- **Result.** A workflow that starts when a `ci.yml` run completes. It turns that run's outcome into the commit status on the commit the run tested, including the one automatic retry.
- **Working rules.** The fork's working rules say when to request CI and what a merge needs.

State and ownership [inferred]: the commit status on a commit is the only result record, owned by GitHub per commit. The evidence for a skip is the `ci.yml` run history: commits whose run concluded `success`. Nothing new is stored.

## API Contracts

- **Request command** [inferred]: one command, runnable from any checkout with the fork's token: start the fork's CI workflow manually with input `pr=<PR number>`. Output: the run's log names the head it judged, the decision (skip with the green commit it compared against, or run), and the status it posted.
- **Status** [inferred]: context `ci (upstream ci.yml)`, the name the check has today. States: `pending` (a run was started, or a retry is in progress), `success` (the run passed, or no code changed since a green commit; the description says which and names that commit), `failure` (failed twice, or failed with no retry left; the description names the first failing tests or points to the run). `target_url` links the run it describes.

## Edge Cases & Constraints

- ci.yml cancels its own run when a job fails, and the failing job usually ends up `cancelled` like the jobs it cancelled; only its error annotation ("Run cancelled by failing job") names it. So job conclusions cannot tell a failure from a superseded run. A run counts as superseded only when the run history shows a newer `ci.yml` run on the same branch, created after it. Every other run that did not succeed (failed, cancelled, timed out) counts as a failure, so no completed run leaves its commit `pending` [inferred].
- `ci.yml` started on a branch tests the branch tip at start time, which can be newer than the head the request read. The result always lands on the commit the run actually tested, never on another one [inferred].
- A push after the request leaves the new head without a status. That means "not requested", never "passed" [paraphrase].
- A green commit that is no longer in the history (a deleted branch that never merged) is not evidence and is ignored [inferred].
- When Actions is paused again, the request fails at start. The owner's rule of 2026-10-13 applies then: a local run replaces CI [inferred].
- `ci.yml` itself stays byte-identical to `wapp/main`: every upstream change to it would otherwise conflict with the upstream sync [paraphrase].

## Acceptance Criteria

- **R1:** A push to a PR into `wapp/main` (opened, synchronize, reopened, ready_for_review) starts no `ci.yml` run and holds no runner waiting for one [paraphrase]. Errors: no error surface; the request (R2) is the only way CI starts for a fork PR.
- **R2:** Requesting CI for a PR judges the PR's current head. When, compared directly (two-commit diff, not a merge base) against a commit whose `ci.yml` run passed, the head differs only in `.flow/**`, Markdown files or `docs/**`, or not at all, it posts a `success` status naming that commit and starts no `ci.yml` run. Otherwise it starts `ci.yml` on the PR branch and posts `pending` [paraphrase]. So a PR that only changes `.flow/` never starts `ci.yml` [paraphrase]. Errors: an unknown or closed PR, a PR whose base is not `wapp/main`, or a head from another repository → the request fails with a message naming the reason and posts no status [inferred]; missing history, an unreadable run list or a failed comparison → `ci.yml` runs, never a skip [paraphrase].
- **R3:** Every path outside `.flow/**`, Markdown files and `docs/**` counts as code, including scripts, workflows, dependency manifests and tests. A merge of `wapp/main` into the PR that brings code therefore runs `ci.yml` [paraphrase]. Errors: no error surface beyond R2.
- **R4:** When a `ci.yml` run completes, its outcome becomes the `ci (upstream ci.yml)` status on the commit that run tested, and no runner polls while it runs [paraphrase]. A first failure re-runs the jobs that did not succeed once while the status stays `pending`; a second failure sets `failure`, its description naming the culprit job when the run's annotations name one. Errors: a run is superseded only when a newer `ci.yml` run on the same branch exists; it is then not retried and posts nothing [inferred]; a failure whose culprit job ended `cancelled` is still a failure, never "superseded" and never left `pending` [inferred]; a run on a commit that is no longer the PR's head updates only that commit's status [inferred].
- **R5:** The fork's working rules say: request CI once the head is final (after any catch-up merge and bookkeeping commits), and merge a fork PR only when its current head has a `success` status; a head without that status was not tested [paraphrase]. Errors: no error surface beyond the rule text.
- **R6:** The original's workflows, `ci.yml` included, are unchanged, and every fork-only workflow file keeps the `wapp-` prefix, so the upstream sync keeps it switched on and a submission to the original never carries it [paraphrase]. Errors: no error surface beyond R2.
- **R7:** The skip decision (R2, R3) and the result decision (R4) are each checked by local tests that need no GitHub: the skip decision against a throwaway git repository with fixture commits and a fixture run list, the result decision against fixture run, job and annotation data, and the GitHub calls through a stand-in `gh` that records what would be posted or started. Cases: code vs `.flow`/Markdown/`docs` change, a catch-up merge that brings code, an empty diff, a green commit missing from history, an unreadable run list, a failed comparison, success, a failure whose culprit ended `cancelled`, a superseded run, a first failure (retry, still `pending`), a second failure, and a request for an unknown, closed, foreign-base or foreign-repository PR. Each test is written first and seen failing for the stated reason [inferred]. Errors: no error surface beyond the cases listed.

## Quick commands

- `actionlint .github/workflows/wapp-fork-ci*.yml` (passes at the spec base; the upstream sync workflow has older shellcheck notes and is not touched).
- From the first task on: the local test command the change adds for R7, run from the repository root.

## Boundaries

- The upstream sync workflow (its six-hourly check and its macOS build on new upstream commits) stays as it is.
- No branch protection or ruleset change; see A4.
- No change to the build loop's own scripts outside this repository; the loop's merge step follows the working rules (R5).
- The local-run rule for times when Actions is off stays as it is.

## Decision Context

- **D1 · CI runs once per PR on request right before the merge, and that run is skipped when no code changed since a commit whose run passed (option C).** why: about 6 in 10 runs disappear (B removes runs replaced before merge, A removes plan-only runs); picked over A and B · status: active [owner-stated 2026-10-14]
- **D2 · This change merges on the local check, and Actions is re-enabled after the merge.** why: "Tell me when its merged o I can enable actions again"; a local run replaces CI while Actions is off (owner rule 2026-10-13) · status: active [owner-stated 2026-10-14]
- **A1 · The skip compares directly against a commit whose run passed, treats every path outside `.flow/**`, Markdown and `docs/**` as code, and runs CI on any missing history or comparison error.** flip at: the request's skip decision · test: R2/R3 skip-decision tests · alternatives: compare against the merge base or the base branch alone (proves nothing about the combination) · status: active [agent-inferred 2026-10-14, Codex gpt-6-astra consult]
- **A2 · Requesting CI is a manual start of the fork's CI workflow with the PR number, not a label or the draft/ready switch.** flip at: the fork CI workflow's trigger · test: R2 request for an unknown PR fails with a message · alternatives: a `ci` label; opening PRs as drafts and starting CI on ready_for_review (a push after ready would need a second trigger anyway) · status: active [agent-assumed 2026-10-14]
- **A3 · The status keeps the name `ci (upstream ci.yml)`, and the one automatic retry stays, now re-running only the jobs that did not succeed.** flip at: the result workflow · test: R4 result-decision tests · alternatives: drop the retry (hosted-runner flakes are still known) · status: active [agent-assumed 2026-10-14]
- **A4 · No required status check in a ruleset; the merge gate stays the documented procedure (R5), as today.** flip at: the fork's rulesets · test: none, procedure only · alternatives: a required `ci (upstream ci.yml)` check (would block the local-run merges while Actions is off and the upstream sync's direct pushes unless bypassed) · status: active [agent-assumed 2026-10-14]
