# Changelog

All notable changes to `@eborja/cortex`.

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
