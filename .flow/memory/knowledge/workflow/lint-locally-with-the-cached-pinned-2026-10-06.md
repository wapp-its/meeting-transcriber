---
title: Lint locally with the cached pinned SwiftFormat and SwiftLint
date: "2026-10-06"
track: knowledge
category: workflow
module: scripts/lint.sh
tags: [lint, swiftformat, swiftlint, local]
applies_when: running ./scripts/lint.sh on the owner's Mac or in a loop worktree
---

SwiftFormat and SwiftLint are not installed globally on the owner's Mac, so `./scripts/lint.sh` alone prints "not found" and checks nothing.

The pinned versions from `scripts/tool-versions.sh` (SwiftFormat 0.63.0, SwiftLint 0.65.1, checksums verified) are cached at `$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin`. Run:

    PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh

Expect "Found 0 violations". Never `brew install` either tool (unpinned, and a global install needs the owner's approval). If the cache is gone, fetch the release assets named in `scripts/tool-versions.sh` and verify their SHA-256 the way `scripts/ci/install-lint-tool.sh` does, into that same cache folder.
