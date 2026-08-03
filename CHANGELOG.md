# Changelog

All notable changes to `@eborja/cortex`.

## 0.2.1 — 2026-08-03

### Added
- **Bounded turns.** `--idle-timeout` (300s) + `--max-turn-duration` (600s), overridable via
  `BUZZ_ACP_IDLE_TIMEOUT` / `BUZZ_ACP_MAX_TURN_DURATION` — a hard per-turn wall-clock ceiling that
  bounds an agent's token cost. This, not a tool deny-list, is how a runaway turn is contained.
- **Per-agent working dir.** Each standing agent runs in its own throwaway dir
  (`<instance>/.cortex/agents/<name>/`) for scratch/log isolation.

### Fixed
- **`cortex restart <agent>` now actually cycles a busy agent.** `stop` waits for the process to exit
  and SIGKILLs a turn that ignores SIGTERM, so `restart` no longer sees it as "already running" and skips.

### Note — tool deny-list explored and dropped
An earlier draft of this release sandboxed each agent's tools (a generated `.claude/settings.json`
`deny` list) to stop a reconcile wandering the filesystem. **It was removed before release** because
it broke the core reply path: a standing agent publishes to Buzz by shelling out to `buzz messages
send`, so denying `Bash` left agents computing correct answers and ending the turn without ever
posting (verified live). Agents now run un-sandboxed (like the working `oracle`), bounded by the turn
caps above. Any future lockdown MUST preserve the shell reply path — e.g. via a first-class Buzz
reply tool — rather than deny `Bash`.

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
