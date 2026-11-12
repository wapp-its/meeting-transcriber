# Run summary CLIs without the user's agent setup

## Conversation Evidence

The fork is public, so the owner's turns are paraphrased, not quoted.

> owner (paraphrased): asked why the installed app was seen in a network monitor connecting to several hosts besides the model provider, among them an MCP server host and a telemetry host.
> owner (paraphrased): picked locking the summary run down through a spec, over only turning telemetry off and over leaving it as it is.
> owner (paraphrased): asked whether the same applies to the other AI tools the app can start.
> owner (selected, paraphrased): ignore the user's own Claude Code settings fully for summary runs.
> owner (selected, paraphrased): leave the custom command provider untouched.

## Goal & Context

The app writes the meeting protocol by starting an AI command-line tool: the Claude CLI, or the Codex CLI preset. Both start with the user's own configuration for that tool, which most users set up for coding work, not for summarising meetings. Measured on a developer machine (Claude CLI 2.1.306, Codex CLI 0.162.1):

- **Claude CLI:** a summary run loaded every MCP server the user configured, the account's claude.ai connectors, all built-in tools including shell commands, the user's permission mode (which may let tools run without asking), the user's hooks, plugins and global instructions file, and sent usage telemetry. A one-word prompt used about 20 times the input tokens of an isolated run.
- **Codex CLI:** already runs with a read-only sandbox and an ephemeral session, but still starts the MCP servers from the user's Codex configuration and runs the configured notify hook.

Why it matters:

- **Untrusted input meets live tools.** The transcript is whatever was said in the meeting, and it reaches the model as input. With tools in reach, a sentence that reads like an instruction could make the model act: send a message through a connected account, run a command, drive the screen. Nothing suggests this has happened; the exposure exists anyway.
- **Cost and drift.** The user's setup is paid for in input tokens on every summary, and the user's coding instructions can shape the protocol.
- **Unexpected traffic.** The app contacts hosts the user never connected to the app.

The user effect after this spec: a summary run gets the transcript and the prompt and nothing else from the user's agent setup; the protocol is written exactly as before, with the same login and model.

<!-- Source: 0% user / 70% [paraphrase] / 30% [inferred] -->

## Architecture & Data Models

- **One launch configuration per run** owns the isolation. The Claude CLI generator already builds its executable, arguments and environment per run, and already decides whether `--no-session-persistence` goes in by reading the CLI's help text once. The isolation options join that same configuration and the same help-text check; nothing is stored outside the run. [inferred]
- **The Codex preset is an argument template plus a per-run lookup.** Codex merges configuration tables, so no single override clears the user's MCP servers. Each run therefore first asks Codex for the configured server names and switches each one off by name, and switches off Codex's connectors (apps), plugins and notify hook. The user's model, reasoning effort and login still come from the user's Codex configuration, as the Settings text promises today. [inferred]
- **The custom command and the providers that start no agent CLI** (OpenAI-compatible HTTP, the local model helper) are outside this change. [paraphrase]

## API Contracts

The contract is what the started tool receives for one summary run.

- **Claude CLI arguments:** today's arguments (`-p - --output-format stream-json --verbose --model sonnet`, plus `--no-session-persistence` when the help lists it), then the isolation options from `## Resolved via Experiment`, each included only when the CLI's help lists it. [inferred]
- **Claude CLI environment:** today's environment (nested-session variable removed, search paths prepended, the app's API key when set, auto memory off), plus the two isolation variables from `## Resolved via Experiment`, always set, overriding any inherited value. A CLI that does not know a variable ignores it. [inferred]
- **Codex CLI arguments:** today's preset (`exec --json --ephemeral --skip-git-repo-check --sandbox read-only --output-last-message {output_file} -`) plus one override that switches every configured MCP server off in a single table value, `-c 'mcp_servers={"<name1>"={enabled=false},"<name2>"={enabled=false}}'`, with each name written as a quoted TOML string (Codex merges this table over the user's, and its override parser splits a dotted key on every dot, so a name like `review.name` only survives inside the value), plus `--disable apps`, `--disable plugins` and `-c notify=[]`. The names come from `codex mcp list --json`, run with the same program, environment and run folder just before the summary run. When that listing fails or cannot be parsed, the run goes ahead without the per-server overrides and logs the warning line (A1's rule). [inferred]
- **Warning line:** when an isolation option is left out because the help does not list it, the run logs one content-free warning per run naming the missing options (option names only, never transcript text or paths). [inferred]

## Edge Cases & Constraints

- **An older Claude CLI** that lacks an option runs without that option and logs the warning; it is never worse than today. [inferred]
- **Provider settings kept only in the user's Claude Code settings file** (for example a gateway URL or a cloud provider switch in its environment block) no longer apply to summary runs. Organisation-managed settings still apply, and the app's own API key field keeps working. This is the accepted cost of ignoring the settings file fully. [paraphrase]
- **A wrapper program** standing in for `claude` (one that sets its own configuration folder) receives the same options and environment; whether it passes them on is its own business. [inferred]
- **Codex's own built-in instructions and global instructions file** still load: no option removes them without also dropping the user's model choice. Known limit. [inferred]
- **No real meeting content in tests or probes.** Live checks use a made-up transcript. [inferred]

## Acceptance Criteria

- **R1:** A Claude CLI summary run has no tools available: the CLI's start-up event lists no built-in tools and no MCP tools. Errors: a CLI whose help does not list the tools option runs without it and logs the warning line naming it. [paraphrase]
- **R2:** A Claude CLI summary run starts no MCP server from any source: none from the user's configuration, none from a project configuration, none of the account's claude.ai connectors. Errors: a CLI whose help does not list the option runs without it and logs the warning line naming it. [paraphrase]
- **R3:** A Claude CLI summary run ignores the user's, project and local Claude Code settings files: no hook runs, no plugin enabled there loads, the user's permission mode and global instructions file do not apply. Errors: a CLI whose help does not list the option runs without it and logs the warning line naming it. [paraphrase]
- **R4:** A Claude CLI summary run sends no nonessential traffic (usage telemetry, error reports): the CLI's start-up event reports analytics disabled. No error surface beyond an older CLI ignoring the variable. [paraphrase]
- **R5:** Login and model are unchanged: a CLI signed in with its own login, and a run with the app's API key field set, each still return a protocol for a made-up transcript, on the same model as before. Errors: a signed-out CLI fails with today's error, unchanged. [inferred]
- **R6:** The Codex CLI preset starts no MCP server from the user's Codex configuration, uses none of Codex's connectors or plugins, and runs no notify hook, while keeping its read-only sandbox, its ephemeral session, and the model, reasoning effort and login from the user's configuration. Proven by behaviour, not by argument shape: in a throwaway Codex home with a harmless sentinel MCP server and a sentinel notify command (each leaves a marker file when it runs), a summary run with a made-up transcript leaves neither marker, and the same setup without the preset's overrides leaves both (positive control). A configured server name containing a dot or another character that is not allowed in a bare TOML key is switched off too. Errors: the server listing fails → the run goes ahead without per-server overrides and logs the warning line; a Codex CLI too old for an option the preset needs fails with today's update hint, unchanged. [paraphrase]

## Boundaries

- The custom command provider is unchanged: no added arguments, no environment changes. [paraphrase]
- No setting to switch the isolation off. [inferred]
- The help-probe timeout and the fail-or-degrade rule for a missing capability are not changed here; that question is open on #85. [inferred]
- The OpenAI-compatible and local model providers are not touched; they start no agent CLI. [inferred]
- Submitting this to the original project is a separate step, not part of this spec. [inferred]

## Decision Context

- **D1 · Lock the summary run down instead of only turning telemetry off or blocking hosts in a firewall.** why: tools stay in reach while the model reads untrusted transcript text, and a firewall rule protects one machine only · alternatives: B telemetry off only, C leave it and block hosts locally · status: active [owner-ratified 2026-11-06]
- **D2 · The Codex CLI preset gets the same treatment.** why: the owner asked whether other AI tools are affected, and Codex was measured loading its configured MCP servers and notify hook · status: active [owner-ratified 2026-11-06]
- **D3 · The user's Claude Code settings files are ignored entirely for summary runs.** why: simplest and strongest, proven in a test run with login intact; switching settings off one by one lets each new CLI feature back in, and the global instructions file cannot be switched off that way · alternatives: B keep the settings file and switch parts off · status: active [owner-ratified 2026-11-06]
- **D4 · The custom command provider stays untouched, without a settings hint.** why: the app cannot know another tool's options, and the user chose that command · alternatives: add one sentence in Settings (declined) · status: active [owner-ratified 2026-11-06]
- **D5 · Codex keeps the model, reasoning effort and login from the user's configuration; its MCP servers, connectors, plugins and notify hook are switched off.** why: the Settings text promises model and effort from Codex's configuration, and the summary quality stays as the user set it · alternatives: ignore the whole Codex configuration as D3 does for Claude · status: active [owner-ratified 2026-11-12]
- **A1 · An isolation option the installed Claude CLI does not list in its help is left out, and the run goes ahead with a content-free warning, the same rule session persistence follows today.** flip at: the decision on #85 (fail or degrade for a missing capability, one rule for every preset) · test: a launch-configuration unit test with a help text lacking each option · status: active [agent-assumed 2026-11-06]
- **A2 · Codex keeps the model and login from the user's configuration; only its MCP servers and notify hook are overridden.** flip at: a Codex option that drops the user configuration but keeps the model · test: a preset-arguments unit test · status: superseded by A4 [agent-inferred 2026-11-06]
- **A3 · No setting to switch the isolation off.** flip at: a user report that needs their own agent setup inside summaries · test: none, an absence · status: active [agent-assumed 2026-11-06]
- **A4 · Codex keeps the model, reasoning effort and login from the user's configuration; its MCP servers are switched off one by one by name, plus its connectors, plugins and notify hook.** why: the Settings text promises model and effort from Codex's configuration, and the one switch that drops everything (`--ignore-user-config`) breaks that promise · flip at: the owner prefers ignoring the whole Codex configuration as D3 does for Claude, with Codex's default model · test: R6's sentinel run · alternatives: B `--ignore-user-config` · status: superseded by D5 [agent-assumed 2026-11-06]

FIT: GO · 2026-11-12 · base 98c2184d · engine flow-next 9.9.1 · the Claude CLI launcher, its session-persistence file and the Codex preset are unchanged since the plan review; gh-189/gh-190 touched only template and regeneration code; no open issue or PR in the original covers this

## Resolved via Experiment

Measured on 2026-10-21 and 2026-11-06 with a one-word prompt, from an empty folder, on a machine with a typical coding agent setup.

- **Claude CLI 2.1.306, today's arguments:** start-up event listed the user's MCP servers (including claude.ai connectors), 172 tools including shell commands, permission mode `auto`, seven start-up hooks and the user's plugins.
- **Claude CLI 2.1.306 with `--tools ""`, `--strict-mcp-config` (no `--mcp-config`), `--setting-sources ""`, and the environment variables `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and `ENABLE_CLAUDEAI_MCP_SERVERS=false`:** no tools, no MCP servers, no hook events, `analytics_disabled: true`, permission mode `default`, login through the CLI's own sign-in still worked, input about 20 times smaller. Which of the two MCP-related settings removes the claude.ai connectors was not separated.
- **`--bare` was rejected:** its help says it never reads the CLI's own sign-in or keychain, so a subscription login would stop working.
- **Codex CLI 0.162.1, today's preset:** the user's configured MCP servers start and the notify hook is configured. `-c 'mcp_servers={}'` does **not** clear them: configuration tables merge, and `codex mcp list --json` still shows the servers enabled with that override (found in plan review; the smaller input seen earlier was not evidence). Switching servers off works through one table value, `-c 'mcp_servers={"<name>"={enabled=false},…}'`: `codex mcp list --json` then shows every server disabled, also together with `--disable apps --disable plugins`. The dotted-key form `-c 'mcp_servers.<name>.enabled=false'` works for plain names only: Codex splits the key on every dot, so a server named `review.name` makes the run fail (found in plan review). `-c 'notify=[]'` is expected to clear the hook; not measured, which is why R6 asks for a sentinel. `--ignore-user-config` drops all of it at once but also drops the user's model and reasoning effort, which the Settings text says come from Codex's configuration.
