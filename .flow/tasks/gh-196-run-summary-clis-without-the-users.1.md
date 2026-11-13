---
satisfies: [R1, R2, R3, R4, R5, R6]
---
# gh-196-run-summary-clis-without-the-users.1 Implement Run summary CLIs without the user's agent setup

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
Claude CLI and Codex CLI summary runs now start without the user's own agent setup. Claude gets `--tools ""`, `--strict-mcp-config` and `--setting-sources ""`, each only when its `--help` lists it, plus `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and `ENABLE_CLAUDEAI_MCP_SERVERS=false`. Codex gets `--disable apps`, `--disable plugins`, `-c notify=[]` and a per-run `-c mcp_servers={...}` that switches off every configured server by name. The custom command is unchanged.

stage: impl-review - ran [2 rounds; SHIP at 2026-11-12T20:33:38Z]
Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

Review rounds (codex gpt-6-astra, effort xhigh, receipt /tmp/impl-review-receipt-321b56f71023-gh-196-run-summary-clis-without-the-users.1.json):
- Round 1, three-draw fan-out, rid 4376feb31acb410b84c023695b61b0b3: NEEDS_WORK, 1 finding (P2, R6). A Codex without the plugins feature fails on `--disable plugins` with "Unknown feature flag" and showed no update hint. The validator kept it. Fixed in 23a7ed3c (failing test) and 864e45df (fix).
- Round 2, single re-review resuming the primary session: SHIP. Prior finding fixed, R1-R6 met, 0 new findings. Nothing declined.

Gates on the final head:
- Focused tests (generators, settings, template, runner, API key, callers: AppStateTests, ProtocolDestination, ProtocolGenerator, ProtocolTemplateDelivery): 384 run, 383 passed. ClaudeCLIProtocolGeneratorRunnerTests.testGenerateTimesOutACLIThatPrintsNothing missed its 5 s guard once at load 7 to 8; this diff does not change the run path. A re-run of the class passed 5/5 (2.6 s), and the same test passed 1.5 s earlier on this code.
- Lint (pinned SwiftFormat 0.64.5, SwiftLint 0.65.1): 0 files to format, 0 violations.
- scripts/tests/test_*.sh: 30/30 passed.
- Analyze: INCONCLUSIVE. The clean xcodebuild build-for-testing succeeded. Full `swiftlint analyze --strict` did not finish: an endpoint scanner throttled per-file reads, and the run reached 142 of 1054 files in 24 minutes. As a stand-in, unused_declaration (the only analyzer rule) was checked over the whole committed tree: every added non-test declaration is referenced, and no removed call leaves a declaration unused. The full analyze must run in fork CI (`ci.yml`) before merge.

Live checks (made-up transcript only):
- R1-R4 Claude (measured, CLI 2.1.322): the app's exact arguments and environment from an empty folder. The start-up event shows tools [], mcp_servers [], 0 hook events, analytics_disabled true and permissionMode default; the summary text came back.
- R5 Claude: the CLI's own sign-in is measured (apiKeySource none, summary returned). The API-key path is covered by a unit test only, unverified live.
- R6 Codex (measured, CLI 0.162.1): run through the app's generate() with a throwaway CODEX_HOME. Sentinel stdio servers (one name with a dot), an HTTP sentinel server and a sentinel notify command left no marker and got no request. Without the overrides, the mcp-plain, mcp-dot and notify markers appeared and the HTTP server was contacted. Unknown-feature wording measured: "Error: Unknown feature flag: <name>", exit 1.
- R6 listing failure leads to a warning and the run goes ahead: covered by unit test, not run live.

Assumptions added: A5 (help memory per option and the generalised refusal retry), A6 (Codex listing timeout of 10 s; a failed or unreadable listing means a warning and the run goes ahead).

Follow-ups (not fixed, outside the ACs):
- `codex mcp list --json` sends OAuth discovery requests to the host of every HTTP MCP server (measured against a local stand-in). The summary run itself contacts none.
- Codex hooks.json: a sentinel hook never fired under `codex exec` 0.162.1, with or without the overrides. It is not switched off explicitly.
- Codex computer_use/browser_use features: default state under exec not measured.
- Codex global instructions (AGENTS.md in CODEX_HOME) still load (known limit, spec A4/D5).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 21286fc01967e0909b9ec6e439d854ca953e46a8, 2b28c28d99d880ffaec8634c68e15130f6e3d8d4, 23a7ed3c974525597e75d1fa317aff91e6ce1bb6, 864e45df0dd1a9109d1e8480e461264e6559839a
- Tests: cd app/MeetingTranscriber && swift test --skip-build --filter 'ClaudeCLIProtocolGenerator|CommandProtocolGenerator|CommandProviderSettings|CommandTemplate|CLIProcessRunner|AppSettingsClaudeAPIKey|ProtocolTemplateBackgroundLogging|AppStateTests|ProtocolDestinationTests|ProtocolGeneratorTests|ProtocolTemplateDeliveryTests' (384 run, 383 passed; RunnerTests timeout guard missed once under load, class re-run 5/5), ./scripts/lint.sh (pinned SwiftFormat 0.64.5, SwiftLint 0.65.1): 0 violations, scripts/tests/test_*.sh: 30/30 passed, INCONCLUSIVE: swiftlint analyze --strict did not finish locally (file reads throttled); unused_declaration checked over the tree instead; full analyze due in fork CI
- PRs: