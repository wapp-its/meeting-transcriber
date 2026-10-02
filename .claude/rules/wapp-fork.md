# wapp-its fork — working rules

This checkout is the University of Basel fork `wapp-its/meeting-transcriber` of the
MIT-licensed original `pasrom/meeting-transcriber`. These rules belong to the fork
and never travel to the original. The original's own `CLAUDE.md` / `AGENTS.md` stay
untouched by fork work.

## Remotes and branches

- `origin` = `github.com/wapp-its/meeting-transcriber` (the fork), `upstream` =
  `github.com/pasrom/meeting-transcriber` (the original).
- **`wapp/main` is the fork's home and default branch:** `upstream/main` plus `.flow/`,
  this file, and every feature the fork has finished. Features arrive only through
  merged fork PRs (flow-next specs); upstream comes in by merging `upstream/main`.
  No direct commits of app code.
- Each improvement is its own branch: `feat/*` may go to the original later,
  `local/*` stays in the fork. Spec work (flow-next) branches from `wapp/main`.
- **Never wait for the original's maintainer** (owner, 2026-10-02: not very active).
  A feature is done for us when it is merged into `wapp/main` and installed via
  `mt-update`; a PR to the original is optional and fire-and-forget, never a
  dependency and never a reason to park work.
- Branch `tools` holds the fork's tooling: `mt-update.sh` (builds `upstream/main`
  plus every branch in `branches.txt` and installs
  `/Applications/MeetingTranscriber-Dev.app`), `branches.txt`, `submit.sh`.
- Never work inside `~/Library/Application Support/mt-update/` — mt-update resets it.

## Identity, accounts, outward actions

- Git identity, repo-local: `Tobias Flach <tobias.flach@unibas.ch>`.
- GitHub as `wapp-its`, always explicitly:
  `GH_TOKEN=$(gh auth token --user wapp-its) gh …`. Never `gh auth switch`, never a
  token in a git config. Push with a one-off credential helper:
  `git -c credential.helper= -c 'credential.helper=!f() { echo username=wapp-its; echo password=$(gh auth token --user wapp-its); }; f' push …`
- Pushes to the fork, fork issues and fork PRs are free.
- **Anything reaching the original** — a PR, issue, comment, "ready for review", or a
  push to a branch that is the head of an open PR there (e.g. `feat/custom-whisperkit-model`
  for #759, `feat/nemotron-diarization` for #760) — **only after the owner's explicit "go".**
- No AI attribution in commits, PRs or issues.
- No real meeting recordings or transcripts in an agent's context (confidential).
  Logs without content are fine.

## flow-next in this fork

- Tracker: the fork's GitHub issues; spec ids are tracker-first (`gh-<issue>-<slug>`).
- **Every PR flow-next opens targets `wapp/main` in the fork, never the original:**
  `/flow-next:make-pr --base wapp/main`. `gh repo set-default wapp-its/meeting-transcriber`
  must be set in the checkout (make-pr and the tracker follow gh's default repo).
- Before a fork PR, check that its head does not modify `CLAUDE.md` / `AGENTS.md`
  unless the change is meant for the original and the owner agreed.
- Submitting to the original goes only through `submit.sh` on branch `tools`, after
  the owner's "go": it rebuilds `submit/<name>` on the newest `upstream/main` from the
  branch's code commits (without `.flow/`) and refuses any diff that touches `.flow/`,
  `.claude/rules/`, `CLAUDE.md` or `AGENTS.md`, or commit messages that reference fork
  issues or spec ids. Write commit messages for the original's readers: no `#N` of
  fork issues, no `gh-N`/`fn-N` ids.
- Our build: `branches.txt` on `tools` lists `wapp/main` (all merged fork features)
  plus older branches made before flow-next (`feat/custom-whisperkit-model`,
  `feat/nemotron-diarization`, `local/diagnostics`). After a fork PR merges, run
  `mt-update` (see below); a new branch only needs its own `branches.txt` line when
  it must be tried before its merge.
- **CI for fork PRs:** `.github/workflows/wapp-fork-ci.yml` starts the original's
  `ci.yml` (lint, analyze, tests for both variants) on every PR into `wapp/main`; the
  run shows on the PR's head commit. A fork PR merges once that run is green and the
  local review receipts are clean: `gh pr merge --merge --match-head-commit <sha>`.
  Hosted runners, macOS included, are free for this public repo.
- **Upstream sync:** `.github/workflows/wapp-upstream-sync.yml` runs every 6 h. Clean,
  building upstream changes are merged into `wapp/main` and pushed automatically; a
  conflict, a failed build or a refused push opens one issue labelled `upstream-sync`,
  which closes itself after the next clean run. Treat an open `upstream-sync` issue as
  the next thing to fix: merge `upstream/main` into a branch from `wapp/main`, resolve,
  fork PR. Merges touching `.github/workflows` need the `WAPP_SYNC_TOKEN` secret.
- **Only `ci.yml` and `wapp-*` workflows are switched on** in the fork; the sync
  switches off any other workflow upstream adds. The rest of the original's workflows
  need its self-hosted runner, publish its site or cut releases. Fork-only workflows
  are named `wapp-*.yml` so `submit.sh` keeps them out of submissions.

<!-- flow-next:model-routing:start -->
- implementer: opus at xhigh
- reviewer: codex gpt-6-astra at xhigh (plan-review, spec-completion); codex gpt-5.6-sol at xhigh per task
<!-- flow-next:model-routing:end -->

## Trying a change in the installed app

- After pushing a branch listed in `branches.txt`, run `mt-update` yourself to get the
  change into `/Applications/MeetingTranscriber-Dev.app`; do not ask the owner to
  restart the app.
- `mt-update` restarts the app only when it is idle: it builds first, then waits
  (up to 3 h, polling every 30 s) while a recording runs or a job is waiting,
  transcribing, diarizing or generating a protocol, and only then quits and replaces
  the app. Run it in the background and act on its result. Never quit or kill the app
  any other way (`pkill`, `kill`, `osascript … quit`): the app quits without asking,
  a running recording ends abruptly and a running job starts over.
- Open speaker namings do not block; they reappear after the restart (names typed
  into the dialog but not yet confirmed are lost).
- Failed jobs survive a restart (unless their audio is gone); finished ones are
  dropped from the menu after 60 s.
- Match the app process anchored on its executable,
  `pgrep -f '^/Applications/MeetingTranscriber-Dev.app/Contents/MacOS/MeetingTranscriber'`;
  an unanchored pattern also matches any shell whose command line mentions the path.
- App logs: `/usr/bin/log show --last 10m --predicate 'subsystem == "com.meetingtranscriber"'`
  (in zsh, plain `log` is a shell builtin). Info-level lines are not retained.

## Build, test, lint

- Tests download models into `~/Documents`; redirect them:
  `CFFIXED_USER_HOME=<scratch dir> swift test …`.
- Lint: `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1
  (`scripts/tool-versions.sh`).
