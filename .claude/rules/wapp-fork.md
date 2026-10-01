# wapp-its fork — working rules

This checkout is the University of Basel fork `wapp-its/meeting-transcriber` of the
MIT-licensed original `pasrom/meeting-transcriber`. These rules belong to the fork
and never travel to the original. The original's own `CLAUDE.md` / `AGENTS.md` stay
untouched by fork work.

## Remotes and branches

- `origin` = `github.com/wapp-its/meeting-transcriber` (the fork), `upstream` =
  `github.com/pasrom/meeting-transcriber` (the original).
- **`wapp/main` is the fork's home and default branch:** `upstream/main` plus `.flow/`
  and this file, nothing else. Keep it that way: bring upstream in by merging
  `upstream/main`, never commit app code here.
- Each improvement is its own branch: `feat/*` may go to the original later,
  `local/*` stays in the fork. Spec work (flow-next) branches from `wapp/main`.
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
- To ship a feature in our own build, add its branch to `branches.txt` on `tools`.

<!-- flow-next:model-routing:start -->
- implementer: opus at xhigh
- reviewer: codex gpt-6-astra at xhigh (plan-review, spec-completion); codex gpt-5.6-sol at xhigh per task
<!-- flow-next:model-routing:end -->

## Build, test, lint

- Tests download models into `~/Documents`; redirect them:
  `CFFIXED_USER_HOME=<scratch dir> swift test …`.
- Lint: `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1
  (`scripts/tool-versions.sh`).
