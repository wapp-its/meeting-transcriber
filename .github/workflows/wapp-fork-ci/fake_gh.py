#!/usr/bin/env python3
"""Stand-in for `gh api` in test_fork_ci.py; never used by a workflow.

Answers from the JSON file named by FAKE_GH_FIXTURES, keyed "METHOD path":
    {"GET repos/o/r/pulls/7": {"json": {...}}, "POST repos/o/r/...": {"exit": 1}}
An unknown GET fails like a 404; an unknown POST succeeds with no output.
Every call is appended as one JSON line to the file named by FAKE_GH_LOG.
"""
import json
import os
import sys


def main(argv):
    if not argv or argv[0] != "api":
        sys.stderr.write("fake gh: only `gh api` is supported\n")
        return 2
    method, path, fields = "GET", None, {}
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg in ("--method", "-X"):
            method = argv[i + 1]
            i += 2
        elif arg in ("-f", "-F", "--raw-field", "--field"):
            key, _, value = argv[i + 1].partition("=")
            fields[key] = value
            i += 2
        elif path is None:
            path = arg
            i += 1
        else:
            sys.stderr.write("fake gh: unexpected argument %r\n" % arg)
            return 2
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps({"method": method, "path": path, "fields": fields,
                              "token": os.environ.get("GH_TOKEN")}) + "\n")
    with open(os.environ["FAKE_GH_FIXTURES"]) as f:
        fixtures = json.load(f)
    answer = fixtures.get("%s %s" % (method, path))
    if answer is None:
        if method == "GET":
            sys.stderr.write("gh: Not Found (HTTP 404)\n")
            return 1
        return 0
    if answer.get("exit", 0) != 0:
        sys.stderr.write(answer.get("stderr", "gh: HTTP 422") + "\n")
        return answer["exit"]
    if "json" in answer:
        sys.stdout.write(json.dumps(answer["json"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
