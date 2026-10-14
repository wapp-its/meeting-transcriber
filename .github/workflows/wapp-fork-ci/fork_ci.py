#!/usr/bin/env python3
"""Fork CI on request: decides, starts and reports the original's ci.yml for one fork PR.

Fork-only (wapp-its/meeting-transcriber). It lives under .github/workflows/wapp-*
because submit.sh keeps that path out of every submission to the original, and
GitHub reads no workflow from a subdirectory there.

    fork_ci.py request --repo <owner/name> --pr <n> [--fetch] [--self-url <url>]
        Judges the PR's current head. When it differs from a commit whose ci.yml run
        passed only in .flow/, Markdown or docs/ (or not at all), it posts a success
        status naming that commit and starts nothing. Otherwise it starts ci.yml on
        the PR branch and posts a pending status. Started by wapp-fork-ci.yml.

    fork_ci.py result --repo <owner/name> --run-id <id> --attempt <n>
        Turns one completed ci.yml run attempt into the status on the commit it
        tested: success; a first failure is re-run once; a second failure fails; a
        run superseded by a newer one on the same branch posts nothing. Started by
        wapp-fork-ci-result.yml, and runnable by hand if that workflow did not fire.

Talks to GitHub only through `gh api`, so test_fork_ci.py can stand in for it.
"""
import argparse
import json
import re
import subprocess
import sys
from urllib.parse import quote

CONTEXT = "ci (upstream ci.yml)"
HOME_BRANCH = "wapp/main"
GREEN_CANDIDATES = 50
CULPRIT = re.compile(r"'(.+?)' failed and cancelled this run")


class GhError(Exception):
    pass


class GitError(Exception):
    pass


def is_code_path(path):
    """Everything is code except plan files, Markdown and docs/ (owner decision on #128)."""
    if path.startswith(".flow/") or path.startswith("docs/"):
        return False
    return not path.endswith(".md")


def gh(method, path, **fields):
    args = ["gh", "api", "--method", method, path]
    for key, value in fields.items():
        args += ["-f", "%s=%s" % (key, value)]
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise GhError((proc.stderr or proc.stdout).strip() or "gh api %s %s failed" % (method, path))
    return json.loads(proc.stdout) if proc.stdout.strip() else None


def post_status(repo, sha, state, description, target_url):
    if len(description) > 140:
        description = description[:139] + "…"
    gh("POST", "repos/%s/statuses/%s" % (repo, sha), state=state, context=CONTEXT,
       description=description, target_url=target_url)
    print("status %s on %s: %s" % (state, sha[:8], description))


class Git:
    def has_commit(self, sha):
        return subprocess.run(["git", "cat-file", "-e", sha + "^{commit}"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

    def changed_paths(self, a, b):
        # --no-renames: a move out of the app into docs/ must still show its source path
        proc = subprocess.run(["git", "diff", "--no-renames", "--name-only", a, b],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if proc.returncode != 0:
            raise GitError(proc.stderr.strip())
        return [line for line in proc.stdout.splitlines() if line]


def decide_skip(head_sha, green_runs, git):
    """Returns ("skip", run, reason) or ("run", None, reason). Doubt always runs."""
    if green_runs is None:
        return "run", None, "the run list of passing ci.yml runs was unreadable"
    if not git.has_commit(head_sha):
        return "run", None, "the head %s is not in the history" % head_sha[:8]
    compared = None
    seen = set()
    for run in green_runs:
        sha = run.get("head_sha") or ""
        if not sha or sha in seen or not git.has_commit(sha):
            continue
        seen.add(sha)
        try:
            paths = git.changed_paths(sha, head_sha)
        except GitError as e:
            return "run", None, "the comparison failed against %s: %s" % (sha[:8], e)
        if not any(is_code_path(p) for p in paths):
            return "skip", run, "no code change since %s, whose ci.yml run passed" % sha[:8]
        if compared is None:
            compared = (sha, [p for p in paths if is_code_path(p)])
    if compared is None:
        return "run", None, "no passing ci.yml run on a commit in the history"
    sha, code = compared
    return "run", None, "code changed since %s (the last passing run): %s" % (
        sha[:8], ", ".join(code[:3]) + (" …" if len(code) > 3 else ""))


def request(args):
    try:
        pr = gh("GET", "repos/%s/pulls/%d" % (args.repo, args.pr))
    except GhError as e:
        sys.exit("PR #%d could not be read: %s" % (args.pr, e))
    if pr.get("state") != "open":
        sys.exit("PR #%d is not open (state: %s)" % (args.pr, pr.get("state")))
    if pr["base"]["ref"] != HOME_BRANCH:
        sys.exit("PR #%d goes into %s, not %s" % (args.pr, pr["base"]["ref"], HOME_BRANCH))
    head_repo = (pr["head"].get("repo") or {}).get("full_name")
    if head_repo != args.repo:
        sys.exit("PR #%d comes from another repository (%s); CI runs only for branches of %s"
                 % (args.pr, head_repo or "deleted", args.repo))
    head_sha, head_ref = pr["head"]["sha"], pr["head"]["ref"]

    if args.fetch:
        subprocess.run(["git", "fetch", "--quiet", "origin", "+refs/pull/%d/head" % args.pr])
    try:
        runs = gh("GET", "repos/%s/actions/workflows/ci.yml/runs?status=success&per_page=%d"
                  % (args.repo, GREEN_CANDIDATES))["workflow_runs"]
    except (GhError, KeyError, TypeError) as e:
        print("passing runs unreadable: %s" % e)
        runs = None

    action, green, reason = decide_skip(head_sha, runs, Git())
    print("PR #%d head %s: %s, %s" % (args.pr, head_sha[:8], action, reason))
    if action == "skip":
        post_status(args.repo, head_sha, "success", reason[0].upper() + reason[1:], green["html_url"])
        return
    try:
        gh("POST", "repos/%s/actions/workflows/ci.yml/dispatches" % args.repo, ref=head_ref)
    except GhError as e:
        sys.exit("could not start ci.yml on %s: %s" % (head_ref, e))
    post_status(args.repo, head_sha, "pending", "ci.yml started: " + reason, args.self_url)


def superseded(repo, run):
    """A newer ci.yml run on the same branch replaced this one. Unreadable counts as no."""
    try:
        runs = gh("GET", "repos/%s/actions/workflows/ci.yml/runs?branch=%s&per_page=30"
                  % (repo, quote(run["head_branch"], safe="")))["workflow_runs"]
    except (GhError, KeyError, TypeError):
        return False
    return any(r["id"] != run["id"] and r["created_at"] > run["created_at"] for r in runs)


def find_culprit(repo, run_id, attempt):
    """The failing job's name: a job concluded `failure`, else the cancel-on-failure annotation."""
    try:
        jobs = gh("GET", "repos/%s/actions/runs/%d/attempts/%d/jobs?per_page=100"
                  % (repo, run_id, attempt))["jobs"]
    except (GhError, KeyError, TypeError):
        return None
    for job in jobs:
        if job.get("conclusion") == "failure":
            return job["name"]
    for job in jobs:
        if job.get("conclusion") == "success":
            continue
        check_run = (job.get("check_run_url") or "").rsplit("/", 1)[-1] or str(job["id"])
        try:
            notes = gh("GET", "repos/%s/check-runs/%s/annotations" % (repo, check_run)) or []
        except GhError:
            continue
        for note in notes:
            match = CULPRIT.search(note.get("message") or "")
            if match:
                return match.group(1)
    return None


def result(args):
    try:
        run = gh("GET", "repos/%s/actions/runs/%d/attempts/%d" % (args.repo, args.run_id, args.attempt))
    except GhError as e:
        sys.exit("run %d attempt %d could not be read: %s" % (args.run_id, args.attempt, e))
    sha, url = run["head_sha"], run["html_url"]
    if run.get("status") != "completed":
        print("run %d attempt %d is %s; nothing to report" % (args.run_id, args.attempt, run.get("status")))
        return
    if run.get("conclusion") == "success":
        post_status(args.repo, sha, "success", "ci.yml passed" + (" on retry" if args.attempt > 1 else ""), url)
        return
    if superseded(args.repo, run):
        print("run %d was superseded by a newer ci.yml run on %s; nothing to report"
              % (args.run_id, run["head_branch"]))
        return
    culprit = find_culprit(args.repo, args.run_id, args.attempt)
    what = culprit or "see the run"
    if args.attempt > 1:
        post_status(args.repo, sha, "failure", "ci.yml failed twice: " + what, url)
        return
    for kind in ("rerun-failed-jobs", "rerun"):
        try:
            gh("POST", "repos/%s/actions/runs/%d/%s" % (args.repo, args.run_id, kind))
        except GhError as e:
            print("%s refused: %s" % (kind, e))
            continue
        post_status(args.repo, sha, "pending", "First attempt failed (%s), retrying once" % what, url)
        return
    post_status(args.repo, sha, "failure", "ci.yml failed (%s); the retry could not start" % what, url)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("request")
    p.add_argument("--repo", required=True)
    p.add_argument("--pr", type=int, required=True)
    p.add_argument("--fetch", action="store_true", help="fetch the PR head from origin first")
    p.add_argument("--self-url", default="", help="link for the pending status")
    p.set_defaults(func=request)
    r = sub.add_parser("result")
    r.add_argument("--repo", required=True)
    r.add_argument("--run-id", type=int, required=True)
    r.add_argument("--attempt", type=int, required=True)
    r.set_defaults(func=result)
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
