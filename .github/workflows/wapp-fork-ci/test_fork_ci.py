"""Tests for fork_ci.py, run locally without GitHub:

    python3 -m unittest discover -s .github/workflows/wapp-fork-ci -p 'test_*.py'

Each test drives the real command line against a throwaway git repository and a
stand-in `gh` (fake_gh.py) that answers from fixtures and records every call.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "fork_ci.py")
FAKE_GH = os.path.join(HERE, "fake_gh.py")
REPO = "wapp-its/meeting-transcriber"
CONTEXT = "ci (upstream ci.yml)"

sys.path.insert(0, HERE)
import fork_ci  # noqa: E402

GIT_ENV = {
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.invalid",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
}


class Harness:
    def __init__(self, testcase):
        self.tmp = tempfile.mkdtemp(prefix="wapp-fork-ci-")
        testcase.addCleanup(shutil.rmtree, self.tmp)
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        self.git("init", "-q", "-b", "wapp/main")
        bindir = os.path.join(self.tmp, "bin")
        os.makedirs(bindir)
        gh = os.path.join(bindir, "gh")
        with open(gh, "w") as f:
            f.write('#!/bin/sh\nexec "%s" "%s" "$@"\n' % (sys.executable, FAKE_GH))
        os.chmod(gh, 0o755)
        self.path = bindir + os.pathsep + os.environ.get("PATH", "")
        self.fixtures = {}
        self.log = os.path.join(self.tmp, "gh-calls.jsonl")

    def git(self, *args):
        env = dict(os.environ, **GIT_ENV)
        out = subprocess.run(["git", *args], cwd=self.repo, env=env, check=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return out.stdout.strip()

    def commit(self, files, message="change"):
        for path, content in files.items():
            full = os.path.join(self.repo, path)
            if content is None:
                self.git("rm", "-q", path)
                continue
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as f:
                f.write(content)
            self.git("add", path)
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def base(self):
        return self.commit({
            "app/Sources/Code.swift": "let a = 1\n",
            "docs/guide.md": "guide\n",
            "README.md": "readme\n",
            ".flow/specs/x.json": "{}\n",
        }, "base")

    def pr(self, head_sha, number=7, ref="feat/x", state="open", base="wapp/main", head_repo=REPO):
        repo = {"full_name": head_repo} if head_repo else None
        self.fixtures["GET repos/%s/pulls/%d" % (REPO, number)] = {"json": {
            "number": number, "state": state,
            "base": {"ref": base},
            "head": {"sha": head_sha, "ref": ref, "repo": repo},
        }}

    def green(self, *shas, event="workflow_dispatch", page=1, first_id=100):
        runs = [{"id": first_id + i, "head_sha": sha, "event": event,
                 "html_url": "https://example.invalid/runs/%d" % (first_id + i)}
                for i, sha in enumerate(shas)]
        self.fixtures["GET repos/%s/actions/workflows/ci.yml/runs?status=success&per_page=100&page=%d"
                      % (REPO, page)] = {"json": {"workflow_runs": runs}}

    def run(self, *args, dispatch_token="personal-token"):
        with open(os.path.join(self.tmp, "fixtures.json"), "w") as f:
            json.dump(self.fixtures, f)
        env = dict(os.environ, **GIT_ENV)
        env.pop("DISPATCH_TOKEN", None)
        env.update(PATH=self.path, FAKE_GH_FIXTURES=os.path.join(self.tmp, "fixtures.json"),
                   FAKE_GH_LOG=self.log, GH_TOKEN="workflow-token")
        if dispatch_token is not None:
            env["DISPATCH_TOKEN"] = dispatch_token
        return subprocess.run([sys.executable, SCRIPT, *args], cwd=self.repo, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def request(self, pr=7, dispatch_token="personal-token"):
        return self.run("request", "--repo", REPO, "--pr", str(pr),
                        "--self-url", "https://example.invalid/request", dispatch_token=dispatch_token)

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return [json.loads(line) for line in f]

    def writes(self):
        return [c for c in self.calls() if c["method"] != "GET"]

    def statuses(self):
        return [(c["path"].rsplit("/", 1)[1], c["fields"]) for c in self.writes()
                if c["path"].startswith("repos/%s/statuses/" % REPO)]

    def dispatches(self):
        return [c["fields"] for c in self.writes()
                if c["path"] == "repos/%s/actions/workflows/ci.yml/dispatches" % REPO]


class CodePathTests(unittest.TestCase):
    def test_only_flow_markdown_and_docs_are_not_code(self):
        for path in [".flow/specs/a.json", ".flow/tasks/a.1.md", "README.md", "app/Notes.md",
                     ".claude/rules/wapp-fork.md", "docs/automation-api.md", "docs/img/menu.png"]:
            self.assertFalse(fork_ci.is_code_path(path), path)
        for path in ["app/Sources/Code.swift", "scripts/lint.sh", ".github/workflows/ci.yml",
                     ".github/workflows/wapp-fork-ci/fork_ci.py", "app/MeetingTranscriber/Package.resolved",
                     "Casks/meeting-transcriber.rb", "VERSION", "docsx/a.txt", "README.markdown.swift"]:
            self.assertTrue(fork_ci.is_code_path(path), path)


class WorkflowTriggerTests(unittest.TestCase):
    """A push to a fork PR must start nothing; only the request and the result handler run."""

    WORKFLOWS = os.path.dirname(HERE)

    def read(self, name):
        with open(os.path.join(self.WORKFLOWS, name)) as f:
            return f.read()

    def triggers(self, text):
        block = re.search(r"^on:\n((?:[ #].*\n|\n)+)", text, re.M).group(1)
        return re.findall(r"^  ([a-z_]+):", block, re.M)

    def test_no_fork_workflow_starts_on_a_pull_request(self):
        for name in sorted(os.listdir(self.WORKFLOWS)):
            if name.startswith("wapp-") and name.endswith(".yml"):
                with self.subTest(workflow=name):
                    self.assertNotIn("pull_request", self.triggers(self.read(name)))
                    self.assertNotIn("pull_request_target", self.triggers(self.read(name)))

    def test_request_and_result_triggers(self):
        self.assertEqual(self.triggers(self.read("wapp-fork-ci.yml")), ["workflow_dispatch"])
        result = self.read("wapp-fork-ci-result.yml")
        self.assertEqual(self.triggers(result), ["workflow_run"])
        self.assertIn("workflows: [CI]", result)
        self.assertRegex(self.read("ci.yml"), r"(?m)^name: CI$")


class RequestSkipTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness(self)
        self.green_sha = self.h.base()

    def assert_skipped(self, result, head):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.h.dispatches(), [])
        statuses = self.h.statuses()
        self.assertEqual(len(statuses), 1, statuses)
        sha, fields = statuses[0]
        self.assertEqual(sha, head)
        self.assertEqual(fields["state"], "success")
        self.assertEqual(fields["context"], CONTEXT)
        self.assertIn(self.green_sha[:8], fields["description"])
        self.assertLessEqual(len(fields["description"]), 140)
        self.assertEqual(fields["target_url"], "https://example.invalid/runs/100")

    def assert_started(self, result, head, reason_word):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.h.dispatches(), [{"ref": "feat/x"}])
        statuses = self.h.statuses()
        self.assertEqual(len(statuses), 1, statuses)
        sha, fields = statuses[0]
        self.assertEqual(sha, head)
        self.assertEqual(fields["state"], "pending")
        self.assertEqual(fields["context"], CONTEXT)
        self.assertLessEqual(len(fields["description"]), 140)
        self.assertIn(reason_word, result.stdout)
        # the dispatch comes first: a failed start must leave no pending status behind
        writes = [c["path"] for c in self.h.writes()]
        self.assertTrue(writes[0].endswith("/dispatches"), writes)

    def test_flow_only_change_skips(self):
        head = self.h.commit({".flow/specs/x.json": '{"a": 1}\n', ".flow/tasks/x.1.md": "t\n"})
        self.h.pr(head)
        self.h.green(self.green_sha)
        self.assert_skipped(self.h.request(), head)

    def test_markdown_and_docs_only_change_skips(self):
        head = self.h.commit({"README.md": "new\n", "docs/notes.txt": "n\n", "app/CHANGES.md": "c\n"})
        self.h.pr(head)
        self.h.green(self.green_sha)
        self.assert_skipped(self.h.request(), head)

    def test_empty_diff_skips(self):
        head = self.h.commit({}, "empty")
        self.h.pr(head)
        self.h.green(self.green_sha)
        self.assert_skipped(self.h.request(), head)

    def test_code_change_starts_ci(self):
        head = self.h.commit({"app/Sources/Code.swift": "let a = 2\n", ".flow/specs/x.json": "{}{}\n"})
        self.h.pr(head)
        self.h.green(self.green_sha)
        self.assert_started(self.h.request(), head, "code changed")

    def test_ci_is_started_with_the_dispatch_token_and_nothing_else_is(self):
        # a run started with the workflow token would not fire wapp-fork-ci-result.yml
        head = self.h.commit({"app/Sources/Code.swift": "let a = 4\n"})
        self.h.pr(head)
        self.h.green(self.green_sha)
        result = self.h.request()
        self.assertEqual(result.returncode, 0, result.stderr)
        for call in self.h.calls():
            expected = "personal-token" if call["path"].endswith("/dispatches") else "workflow-token"
            self.assertEqual(call["token"], expected, call["path"])

    def test_missing_dispatch_token_still_starts_ci_and_warns(self):
        head = self.h.commit({"app/Sources/Code.swift": "let a = 5\n"})
        self.h.pr(head)
        self.h.green(self.green_sha)
        result = self.h.request(dispatch_token=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.h.dispatches(), [{"ref": "feat/x"}])
        self.assertIn("DISPATCH_TOKEN", result.stdout)
        self.assertIn("by hand", result.stdout)

    def test_scripts_workflows_and_dependencies_count_as_code(self):
        for path in ["scripts/new.sh", ".github/workflows/wapp-x.yml", "app/MeetingTranscriber/Package.resolved"]:
            with self.subTest(path=path):
                h = Harness(self)
                green = h.base()
                head = h.commit({path: "x\n"})
                h.pr(head)
                h.green(green)
                result = h.request()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(h.dispatches(), [{"ref": "feat/x"}])

    def test_rename_from_code_into_docs_starts_ci(self):
        self.h.git("mv", "app/Sources/Code.swift", "docs/Code.swift")
        self.h.git("commit", "-q", "-m", "move")
        head = self.h.git("rev-parse", "HEAD")
        self.h.pr(head)
        self.h.green(self.green_sha)
        self.assert_started(self.h.request(), head, "code changed")

    def test_catch_up_merge_that_brings_code_starts_ci(self):
        # green = the PR head before the catch-up; wapp/main then gained code
        self.h.git("checkout", "-q", "-b", "feat/x")
        feature = self.h.commit({"app/Sources/Feature.swift": "f\n"})
        self.h.git("checkout", "-q", "wapp/main")
        self.h.commit({"app/Sources/Other.swift": "o\n"})
        self.h.git("checkout", "-q", "feat/x")
        self.h.git("merge", "-q", "--no-edit", "wapp/main")
        head = self.h.git("rev-parse", "HEAD")
        self.h.pr(head)
        self.h.green(feature)
        self.assert_started(self.h.request(), head, "code changed")

    def test_catch_up_merge_that_brings_only_plans_skips(self):
        self.h.git("checkout", "-q", "-b", "feat/x")
        feature = self.h.commit({"app/Sources/Feature.swift": "f\n"})
        self.h.git("checkout", "-q", "wapp/main")
        self.h.commit({".flow/specs/y.json": "{}\n"})
        self.h.git("checkout", "-q", "feat/x")
        self.h.git("merge", "-q", "--no-edit", "wapp/main")
        head = self.h.git("rev-parse", "HEAD")
        self.h.pr(head)
        self.green_sha = feature
        self.h.green(feature)
        self.assert_skipped(self.h.request(), head)

    def test_excluded_paths_that_git_quotes_still_skip(self):
        # git quotes non-ASCII names in its plain output; they must still match the exclusions
        head = self.h.commit({"docs/überblick.png": "p\n", ".flow/specs/überblick.json": "{}\n",
                              "app/Überblick.md": "m\n"})
        self.h.pr(head)
        self.h.green(self.green_sha)
        self.assert_skipped(self.h.request(), head)

    def test_passing_commit_beyond_the_first_page_is_found(self):
        # the 100 newest passing runs tested other code; the matching commit is on page 2
        other = self.h.commit({"app/Sources/Elsewhere.swift": "e\n"}, "other code")
        self.h.git("reset", "-q", "--hard", self.green_sha)
        head = self.h.commit({".flow/specs/x.json": "{}{}\n"})
        self.h.pr(head)
        self.h.green(*([other] * 100))
        self.h.green(self.green_sha, page=2)
        self.assert_skipped(self.h.request(), head)

    def test_pull_request_runs_are_not_evidence(self):
        # a pull_request run tests GitHub's merge commit, not the head it names
        head = self.h.commit({".flow/specs/x.json": "{}{}\n"})
        self.h.pr(head)
        self.h.green(self.green_sha, event="pull_request")
        self.assert_started(self.h.request(), head, "no passing")

    def test_green_commit_missing_from_history_starts_ci(self):
        head = self.h.commit({".flow/specs/x.json": "{}{}\n"})
        self.h.pr(head)
        self.h.green("0123456789abcdef0123456789abcdef01234567")
        self.assert_started(self.h.request(), head, "no passing")

    def test_unreadable_run_list_starts_ci(self):
        head = self.h.commit({".flow/specs/x.json": "{}{}\n"})
        self.h.pr(head)
        self.assert_started(self.h.request(), head, "run list")

    def test_head_missing_from_history_starts_ci(self):
        self.h.pr("fedcba9876543210fedcba9876543210fedcba98")
        self.h.green(self.green_sha)
        result = self.h.request()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.h.dispatches(), [{"ref": "feat/x"}])
        self.assertIn("not in the history", result.stdout)

    def test_failed_comparison_starts_ci(self):
        # the head commit exists, but a tree it needs is gone, so the diff fails
        head = self.h.commit({"app/Sources/Deep/New.swift": "n\n"})
        tree = self.h.git("rev-parse", head + ":app/Sources/Deep")
        os.remove(os.path.join(self.h.repo, ".git", "objects", tree[:2], tree[2:]))
        self.h.pr(head)
        self.h.green(self.green_sha)
        self.assert_started(self.h.request(), head, "comparison failed")


class RequestErrorTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness(self)
        self.head = self.h.base()
        self.h.green(self.head)

    def assert_refused(self, result, words):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(words, result.stderr)
        self.assertEqual(self.h.writes(), [])

    def test_unknown_pr(self):
        self.assert_refused(self.h.request(pr=99), "PR #99")

    def test_closed_pr(self):
        self.h.pr(self.head, state="closed")
        self.assert_refused(self.h.request(), "not open")

    def test_pr_into_another_branch(self):
        self.h.pr(self.head, base="main")
        self.assert_refused(self.h.request(), "wapp/main")

    def test_pr_from_another_repository(self):
        self.h.pr(self.head, head_repo="someone/meeting-transcriber")
        self.assert_refused(self.h.request(), "another repository")

    def test_pr_whose_head_repository_is_gone(self):
        self.h.pr(self.head, head_repo=None)
        self.assert_refused(self.h.request(), "another repository")

    def test_failed_dispatch_posts_no_status(self):
        head = self.h.commit({"app/Sources/Code.swift": "let a = 3\n"})
        self.h.pr(head)
        self.h.fixtures["POST repos/%s/actions/workflows/ci.yml/dispatches" % REPO] = {
            "exit": 1, "stderr": "HTTP 422: Actions has been disabled for this repository"}
        result = self.h.request()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Actions has been disabled", result.stderr)
        self.assertEqual(self.h.statuses(), [])


RUN_ID = 555
HEAD = "a" * 40
RUN_URL = "https://example.invalid/runs/555"


class ResultTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness(self)

    def attempt(self, attempt, conclusion, status="completed", created="2026-10-14T10:00:00Z",
                event="workflow_dispatch", path=".github/workflows/ci.yml"):
        """The run as GitHub reports it now: its latest attempt is `attempt`."""
        self.h.fixtures["GET repos/%s/actions/runs/%d" % (REPO, RUN_ID)] = {"json": {
            "id": RUN_ID, "run_attempt": attempt, "status": status, "conclusion": conclusion,
            "event": event, "path": path, "head_sha": HEAD, "head_branch": "feat/x",
            "created_at": created, "html_url": RUN_URL}}

    def branch_runs(self, *runs):
        self.h.fixtures["GET repos/%s/actions/workflows/ci.yml/runs?branch=feat%%2Fx&per_page=30" % REPO] = {
            "json": {"workflow_runs": [{"id": i, "created_at": c} for i, c in runs]}}

    def jobs(self, attempt, *jobs):
        self.h.fixtures["GET repos/%s/actions/runs/%d/attempts/%d/jobs?per_page=100" % (REPO, RUN_ID, attempt)] = {
            "json": {"jobs": [{"id": jid, "name": name, "conclusion": concl,
                               "check_run_url": "https://api.example.invalid/check-runs/%d" % jid}
                              for jid, name, concl in jobs]}}

    def annotations(self, job_id, *messages, page=1):
        self.h.fixtures["GET repos/%s/check-runs/%d/annotations?per_page=100&page=%d" % (REPO, job_id, page)] = {
            "json": [{"message": m} for m in messages]}

    def result(self, attempt):
        return self.h.run("result", "--repo", REPO, "--run-id", str(RUN_ID), "--attempt", str(attempt))

    def reruns(self):
        return [c["path"].rsplit("/", 1)[1] for c in self.h.writes() if "/rerun" in c["path"]]

    def only_status(self):
        statuses = self.h.statuses()
        self.assertEqual(len(statuses), 1, statuses)
        sha, fields = statuses[0]
        self.assertEqual(sha, HEAD)
        self.assertEqual(fields["context"], CONTEXT)
        self.assertEqual(fields["target_url"], RUN_URL)
        self.assertLessEqual(len(fields["description"]), 140)
        return fields

    def test_success_posts_success(self):
        self.attempt(1, "success")
        result = self.result(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.only_status()["state"], "success")
        self.assertEqual(self.reruns(), [])

    def test_superseded_success_posts_nothing(self):
        # a newer run on the branch reports for itself; an older success must not overwrite it
        self.attempt(1, "success")
        self.branch_runs((RUN_ID, "2026-10-14T10:00:00Z"), (556, "2026-10-14T10:05:00Z"))
        result = self.result(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.h.writes(), [])
        self.assertIn("superseded", result.stdout)

    def test_pull_request_run_posts_nothing(self):
        self.attempt(1, "success", event="pull_request")
        result = self.result(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.h.writes(), [])

    def test_other_workflow_named_ci_posts_nothing(self):
        self.attempt(1, "success", path=".github/workflows/other.yml")
        result = self.result(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.h.writes(), [])

    def test_stale_attempt_posts_nothing_and_does_not_retry(self):
        # the result for attempt 1 arrives (or is replayed) after attempt 2 exists
        self.attempt(2, "failure")
        self.branch_runs((RUN_ID, "2026-10-14T10:00:00Z"))
        self.jobs(1, (2, "lint", "failure"))
        result = self.result(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.h.writes(), [])

    def test_culprit_annotation_on_a_later_page_is_found(self):
        self.attempt(2, "cancelled")
        self.branch_runs((RUN_ID, "2026-10-14T10:00:00Z"))
        self.jobs(2, (2, "test (appstore)", "cancelled"))
        self.annotations(2, *["warning %d" % i for i in range(100)])
        self.annotations(2, "'test (appstore)' failed and cancelled this run", page=2)
        self.assertEqual(self.result(2).returncode, 0)
        fields = self.only_status()
        self.assertEqual(fields["state"], "failure")
        self.assertIn("test (appstore)", fields["description"])

    def test_first_failure_retries_and_stays_pending(self):
        self.attempt(1, "failure")
        self.branch_runs((RUN_ID, "2026-10-14T10:00:00Z"))
        self.jobs(1, (1, "lint", "success"), (2, "test (homebrew)", "failure"))
        result = self.result(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.reruns(), ["rerun-failed-jobs"])
        fields = self.only_status()
        self.assertEqual(fields["state"], "pending")
        self.assertIn("test (homebrew)", fields["description"])

    def test_second_failure_fails_naming_the_job(self):
        self.attempt(2, "failure")
        self.branch_runs((RUN_ID, "2026-10-14T10:00:00Z"))
        self.jobs(2, (1, "lint", "success"), (2, "analyze", "failure"), (3, "test (appstore)", "cancelled"))
        result = self.result(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.reruns(), [])
        fields = self.only_status()
        self.assertEqual(fields["state"], "failure")
        self.assertIn("analyze", fields["description"])

    def test_failure_whose_culprit_ended_cancelled_is_a_failure(self):
        # cancel-on-failure repaints the failing job `cancelled`; only its annotation names it
        self.attempt(2, "cancelled")
        self.branch_runs((RUN_ID, "2026-10-14T10:00:00Z"))
        self.jobs(2, (1, "lint", "success"), (2, "test (homebrew)", "cancelled"), (3, "analyze", "cancelled"))
        self.annotations(2, "'test (homebrew)' failed and cancelled this run — sibling jobs marked "
                            "'cancelled' are victims, not causes.")
        self.annotations(3, "The operation was canceled.")
        result = self.result(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        fields = self.only_status()
        self.assertEqual(fields["state"], "failure")
        self.assertIn("test (homebrew)", fields["description"])

    def test_first_cancelled_failure_retries_rather_than_counting_as_superseded(self):
        self.attempt(1, "cancelled")
        self.branch_runs((RUN_ID, "2026-10-14T10:00:00Z"), (554, "2026-10-14T09:00:00Z"))
        self.jobs(1, (2, "test (homebrew)", "cancelled"))
        result = self.result(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.reruns(), ["rerun-failed-jobs"])
        self.assertEqual(self.only_status()["state"], "pending")

    def test_superseded_run_posts_nothing(self):
        self.attempt(1, "cancelled")
        self.branch_runs((RUN_ID, "2026-10-14T10:00:00Z"), (556, "2026-10-14T10:05:00Z"))
        self.jobs(1, (2, "test (homebrew)", "cancelled"))
        result = self.result(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.h.writes(), [])
        self.assertIn("superseded", result.stdout)

    def test_retry_falls_back_to_a_full_rerun(self):
        self.attempt(1, "failure")
        self.branch_runs((RUN_ID, "2026-10-14T10:00:00Z"))
        self.jobs(1, (2, "lint", "failure"))
        self.h.fixtures["POST repos/%s/actions/runs/%d/rerun-failed-jobs" % (REPO, RUN_ID)] = {"exit": 1}
        result = self.result(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.reruns(), ["rerun-failed-jobs", "rerun"])
        self.assertEqual(self.only_status()["state"], "pending")

    def test_retry_that_cannot_start_fails(self):
        self.attempt(1, "failure")
        self.branch_runs((RUN_ID, "2026-10-14T10:00:00Z"))
        self.jobs(1, (2, "lint", "failure"))
        self.h.fixtures["POST repos/%s/actions/runs/%d/rerun-failed-jobs" % (REPO, RUN_ID)] = {"exit": 1}
        self.h.fixtures["POST repos/%s/actions/runs/%d/rerun" % (REPO, RUN_ID)] = {"exit": 1}
        result = self.result(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        fields = self.only_status()
        self.assertEqual(fields["state"], "failure")
        self.assertIn("lint", fields["description"])

    def test_unfinished_run_posts_nothing(self):
        self.attempt(1, None, status="in_progress")
        result = self.result(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.h.writes(), [])

    def test_unreadable_run_fails_without_posting(self):
        result = self.result(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.h.writes(), [])


if __name__ == "__main__":
    unittest.main()
