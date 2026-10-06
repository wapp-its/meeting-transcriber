---
title: "Run Swift tests locally: redirect models, read the log, known env failures"
date: "2026-10-06"
track: knowledge
category: workflow
module: app/MeetingTranscriber/Tests
tags: [swift test, CFFIXED_USER_HOME, flaky, local]
applies_when: verifying a task with swift test before commit or review
related_to: [knowledge/workflow/lint-locally-with-the-cached-pinned-2026-10-06]
---

How to run and read the Swift tests locally (measured 2026-10-06):

- Tests download models into `~/Documents` unless redirected: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<a scratch dir> swift test --parallel --filter <Tests> > <log file> 2>&1`, then read the log. Never pipe a test run into tail/head/grep: the shell reports the last command's status, so a red suite exits 0.
- Environmental failures, not regressions: model-download tests under a fresh `CFFIXED_USER_HOME` (Parakeet E2E, ModelPreload, LiveCaption, `WhisperKitLocalSnapshotTests.testProductionLocatesARealFetchedModel`: no models in the fresh home, parallel downloads hit "transient network error / empty weight.bin"); `MenuBarIconSnapshotTests` flakes in dark mode when another test in the same worker initialised NSApp (dev-only, skipped on CI); `DebugRPCServerIntegrationTests` fail inside the Codex review sandbox, which has no sockets. CI (`ci.yml`, run on every PR into `wapp/main`) is the gate for these.
- Release-build parity: `./scripts/pre-push.sh` catches Sendable diagnostics that debug builds tolerate.
