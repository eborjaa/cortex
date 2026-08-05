# Changelog

All notable changes to `@eborja/cortex`.

## Unreleased

### Added
- **`opencode` (sst/opencode) as an ACP runtime.** `opencode acp` is the official
  Agent Client Protocol server subcommand — same hook the other runtimes expose, same
  JSON-RPC over stdio. Set `BUZZ_SYNAPSE_AGENT_COMMAND=opencode` (global default) or
  `AGENT_<name>_RUNTIME=opencode` per agent. The provider is whatever opencode is
  configured with in `~/.config/opencode/opencode.json` (Anthropic, OpenAI, Ollama,
  custom endpoints, etc.) — no provider-specific code in Cortex. `doctor` probes
  `opencode acp --help` and `opencode --version`. Requires opencode ≥ 1.1.

## 0.3.2 — 2026-08-04

### Fixed
- **An agent's tool shell now carries `BUZZ_PRIVATE_KEY` and `BUZZ_RELAY_URL`.** An agent replies by
  shelling out to `buzz messages send`, but `buzz-acp` takes its identity as a **CLI flag**, so the
  shell running the agent's tools inherited nothing. Every reply had to locate and source the per-agent
  env file first — and a turn that spent its budget on the actual work simply ended without publishing.
  That is a silent failed turn: the human sees no answer and the log shows a clean `end_turn`. Observed
  live 2026-08-04 — oracle ran a full 2-minute investigation and posted nothing; with the export it
  answered the same question in 17 seconds. No new exposure: this is the agent's own identity, which it
  already reads from its own env file. `--relay-url` is still passed explicitly, so the WebSocket
  connection is unaffected by the HTTP URL the CLI needs.
- **`BUZZ_AUTH_TAG` is written single-quoted.** The value is JSON and the env file is `.`-sourced, so an
  unquoted value lost every `"` to shell quote-removal; `buzz-acp` then rejected it with
  `invalid JSON: expected value at line 1 column 2` and **silently fell back** to an unowned agent.

### Changed
- **The NIP-OA owner attestation is now opt-in (`OWNER_ATTESTATION=1`), default OFF.** Attesting an
  agent makes Buzz Desktop set `is_agent: true` for it
  (`desktop/src-tauri/src/nostr_convert.rs`: `is_agent: owner_pubkey.is_some()`), and Desktop's mention
  autocomplete then DROPS any `is_agent` identity absent from Desktop's *own* managed-agent list
  (`useMentions.ts` → `isAgentIdentityInManagedList`) — a gate that runs BEFORE the relay-directory
  invocability check. Net effect: attesting an externally-run agent makes it **un-@mentionable** from a
  Buzz client, in exchange for a "managed by <owner>" label. Verified live 2026-08-04. Observer frames
  do not need the attestation — cortex passes `--agent-owner` explicitly.
- `run-agent` warns when `BUZZ_AUTH_TAG` attests a different owner than `AGENT_OWNER`: the attestation
  wins (buzz-acp resolves it with priority over the flag), silently redirecting observer frames to a
  key the watching client cannot decrypt.
- **`--relay-observer` published nothing without an owner.** Observer frames are encrypted *to the
  owner*, so the flag alone is inert: `buzz-acp` logs `relay observer requested but no agent owner was
  resolved at startup; observer frames will not be published` and continues, leaving the client's
  Activity panel empty for an agent that is demonstrably working. Cortex now resolves **`AGENT_OWNER`**
  (defaulting to the `PUB` in `BUZZ_OWNER_ENV`) and passes `--agent-owner`; startup logs
  `relay observer enabled` / `agent owner: <pubkey>`. `run-agent` warns loudly if `RELAY_OBSERVER=1`
  while no owner resolves, instead of failing silently.

`AGENT_OWNER` is overridable because **the identity you watch from is often not the one you run admin
ops from** — a desktop app and the CLI are separate pubkeys, and frames encrypted to one cannot be read
by the other. Set it to the client where you actually read the Activity panel.

Note: this governs observer delivery and the `respond-to` gate only. The "managed by <owner>" label a
client renders comes from a **NIP-OA owner attestation** in the agent's kind:0 profile, which must be
signed by the owner (`buzz agents draft-create` / `draft-update` → approve in the owner's Buzz client).
A harness cannot self-assert its own ownership, by design.

## 0.3.1 — 2026-08-04

### Added
- **`MODEL` (default `sonnet`) + `AGENT_<name>_MODEL`** — passed through as `buzz-acp --model`. A
  standing agent is long-lived and answers on its own initiative, so its model choice is a **standing
  cost**, not a per-call one; the default is therefore the cheaper mid-tier rather than whatever the
  runtime picks. `MODEL=default` defers to the runtime. `doctor` now prints each agent's model.
  Discover ids with `buzz-acp models --agent-command <runtime>`.
- **`RELAY_OBSERVER` (default on)** — passes `--relay-observer`, which publishes encrypted ACP observer
  frames over the relay. Without it a client's Activity panel reads "No ACP activity yet" for an agent
  that is demonstrably working, because the frames were never sent. Set `RELAY_OBSERVER=0` to mute.

Optional flags are assembled as an array and expanded guarded (`${OPT[@]+…}`) so an unset one
contributes no argument — an empty string would be parsed as a positional, and an empty array trips
`set -u`.

## 0.3.0 — 2026-08-03

### Added
- **The roster is derived from the vault, not hand-maintained.** `STANDING` now defaults to every agent
  whose definition declares `addressable: true` (synapse `decision-0008`), read via
  `cortex_addressable_agents()`. Set `STANDING` in `factory.config` only to deliberately override — a
  test instance running a subset. Adding a watchable agent is a vault edit; no harness change, no
  per-install rewiring. `cortex_autonomous_agents()` exposes the companion `autonomous` flag.

### Fixed
- **`provision` writes `BUZZ_RELAY_URL` into the per-agent env file.** An addressable agent replies by
  shelling out to `buzz messages send`, which needs a key **and** a relay URL. Only the key was written,
  so a freshly provisioned agent could authenticate and still fail to publish — and would guess a URL,
  which fails as a mention-preflight/exit-4 error rather than an auth error. One file now carries
  everything needed to publish. Idempotent; existing env files are upgraded in place.

### Changed
- `doctor` reports "addressable agents (roster derived from the vault)", and a provisioned Buzz profile
  reads "Synapse agent (<name>)" — "standing" no longer names a capability the flags describe precisely.

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
