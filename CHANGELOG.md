# Changelog

All notable changes to `@eborja/cortex`.

## 0.2.1 — 2026-08-03

### Added
- **Per-agent tool sandbox.** Each standing agent runs in its own working dir
  (`<instance>/.cortex/agents/<name>/`) whose generated `.claude/settings.json` denies **only the
  filesystem/web drift vectors** — `Bash`, `Edit`, `Write`, `NotebookEdit`, `WebFetch`, `WebSearch` —
  the tools that let a reconcile wander off into the wrong repo instead of working through the vault
  MCP and delegating. A read-only agent (standard/skeleton surface) also loses `Task`; a full-surface
  orchestrator keeps the synchronous `Task` to delegate to doers. `deny` wins even under
  `bypass-permissions`, so it's enforced, not advisory.
  - **Reply path stays open.** `SendMessage` (the Buzz reply/thread/handover tool) is a *deferred*
    tool the agent must load via `ToolSearch` first — so `ToolSearch`, `SendMessage`, and `Task`
    (full surface) are deliberately **kept**. Denying `ToolSearch` (as an earlier draft did) silently
    killed every autonomous reply: the schema could never load, so the agent answered into the void.
  - Turn cost is bounded **separately** by the turn caps below, not by the deny-list — so the
    scheduling/`Task*` tools do not need denying.
- **Bounded turns.** `--idle-timeout` (300s) + `--max-turn-duration` (600s), overridable via
  `BUZZ_ACP_IDLE_TIMEOUT` / `BUZZ_ACP_MAX_TURN_DURATION` — a hard per-turn wall-clock ceiling that
  bounds token cost independently of the tool sandbox.

### Fixed
- **`cortex restart <agent>` now actually cycles a busy agent.** `stop` waits for the process to exit
  and SIGKILLs a turn that ignores SIGTERM, so `restart` no longer sees it as "already running" and skips.

Install: `npm install @eborja/cortex@^0.2.1`

## 0.2.0 — 2026-08-03

### Added
- **`cortex agents-sync`** — materialize every vault agent (`agent-<id>`) into a Claude Code subagent
  type at `~/.claude/agents/<name>.md` (name + description from the agent's `purpose`, body from
  `synapse render`, full toolset inherited). This lets an orchestrator Task-spawn any agent **by name**
  with the full synapse toolset. Registry-driven — no agent list is hardcoded; add an agent to the
  vault and re-run. `cortex start` runs it automatically so the delegable types stay current.

Install: `npm install @eborja/cortex@^0.2.0`

## 0.1.2 — 2026-08-03

### Fixed
- **Relay restart/reload no longer races the graceful drain.** On SIGTERM the relay drains for up to
  30s while still holding port 3000, so a new relay started immediately could not bind and launchd
  dropped it (symptom: `cortex restart` left the relay down and agents crash-looping). Teardown
  (`stop`, `launchd-unload`) now blocks until :3000 is actually free via `wait_port_free`, and
  start/load wait for it to come up via `wait_port_up` instead of a fixed `sleep` — so `cortex
  restart` reliably brings the relay back.

Install: `npm install @eborja/cortex@^0.1.2`

## 0.1.1 — 2026-07-31

### Added
- README + CONTRIBUTING (usage, architecture, the three-layer model, Buzz attribution, dev bar).

Install: `npm install @eborja/cortex@^0.1.1`

## 0.1.0 — 2026-07-31

### Added
- First release. Extracted the Buzz+Synapse harness out of a personal directory into a reusable,
  de-personalized operator for Synapse standing agents.
- `cortex init | doctor | provision | start | stop | restart | launchd-* | test-mcp | status`.
- Per-agent config (`factory.config`): roster + per-agent hub, render profile, MCP surface, runtime.
- **Prompt-from-render**: each agent's system prompt is generated from `synapse render <agent>
  <hub>`, so behaviour is defined in the vault, not hand-written. `PROMPT_SOURCE=file` to override.
- **Per-agent MCP surface**: each bot gets its own injected surface (e.g. oracle on `standard` never
  sees the create_* tools), so read-only is enforced by the surface, not a prompt.
- Ships no Buzz code; orchestrates a user-installed Buzz (Apache-2.0). See NOTICE.

Install: `npm install @eborja/cortex@^0.1.0`
