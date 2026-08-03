# Changelog

All notable changes to `@eborja/cortex`.

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
