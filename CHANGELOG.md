# Changelog

All notable changes to `@eborja/cortex`.

## 0.5.0 — 2026-08-12

### Added
- **Turn budget is configurable per agent: `AGENT_<name>_MAX_TURN` / `AGENT_<name>_IDLE_TIMEOUT`**
  (globals `BUZZ_ACP_MAX_TURN_DURATION` / `BUZZ_ACP_IDLE_TIMEOUT` still apply as defaults). Needed for
  long workflows, and there are **two** timers where the lower always wins:

  * `MAX_TURN` — absolute wall-clock cap per turn.
  * `IDLE_TIMEOUT` — max seconds of **silence**, reset by any agent stdout. This is the trap: a long
    step that prints nothing (a test suite, a build, a sleep) is indistinguishable from a hung agent,
    so raising only the wall-clock cap changes nothing. Observed live 2026-08-11 —
    `WARN idle timeout (300s) — no agent activity` / `cancelling session …`, and separately
    `hard turn timeout exceeded`, on real workflow runs.

  `doctor` now prints `turn=<idle>s/<max>s` per agent and **warns when idle ≥ max**, which silently
  removes hang detection and leaves the wall-clock cap as the only backstop.

- **`cortex restart --idle [<name>...]` — roll out a config change without killing live work.**
  Config applies at process start, so every change needs a restart; a blanket `cortex restart all`
  destroys whatever turns are in flight, and the failure is invisible — the channel just never gets an
  answer. `--idle` restarts only agents that are not mid-turn and names the ones it skipped, with the
  command to finish the job later. Busy-ness is read from the log (activity after the last
  `turn complete`), since a process can be up while a turn is running.

- **`AGENT_<name>_WORKERS` — parallel workers for ONE agent identity** (`buzz-acp --agents`, 1..32).
  Same pubkey, profile and Activity panel; able to hold turns in N channels at once. With the default
  1, a mention in channel B reacts 👀 and then waits for channel A's turn — up to
  `--max-turn-duration` of silence, which reads as the agent ignoring you rather than queueing
  (buzz-acp requeues; nothing is dropped). Cross-channel mentions never *interrupt*: the mid-turn gate
  is scoped to the incoming event's own channel.

  Verified live 2026-08-11 with two 25-second tasks in different channels — both `sleep 25` calls
  started 0.7s apart, total wall clock 45s where a serialized run needs ~70s.

  **Cost:** each worker is a full runtime subprocess plus its own MCP server, and they share ONE
  working directory and git identity, so two turns can write the same checkout concurrently. Raise it
  for agents whose parallel work is mostly read-only; prefer per-worker checkouts before going high.
  `doctor` prints each agent's worker count.

### Fixed
- **Recorded why `--permission-mode` and `--relay-url` must keep their overridable forms.** The #8
  revert hardcoded `--permission-mode bypass-permissions` (older buzz-acp builds reject the value and
  exit before connecting) and dropped the `ws://` coercion on `--relay-url` (the agent pool starts,
  then dies with `WebSocket error: URL scheme not supported`). Both take an agent down while it says
  nothing in chat; both killed qa-lead on 2026-08-11. The failure modes are now documented inline so a
  future revert cannot quietly reintroduce them.
- **Never put a `#` comment inside the backslash-continued arg list** — line continuation joins the
  lines first, so the comment becomes literal arguments. Produced a start that logged nothing at all.

- **`cortex sync-directory [<name>...]` — refresh kind:10100 channel lists from live membership.**
  `channel_ids` in the directory record is a snapshot taken at publish time and **nothing keeps it
  fresh**: buzz-acp never writes kind:10100, the relay reads only `channel_add_policy` from it, and
  Desktop treats the record as "near-static … this poll is also the ONLY refresh path". So adding an
  agent to a channel from the UI leaves the record stale, which breaks three client behaviours at
  once — the agent's profile channel list/count, the Activity panel's channel resolution
  (`agentChannelIds` comes from this record), and mention-autocomplete eligibility.

  The confusing part: **the agent itself is fine.** buzz-acp joins the new channel live off a
  membership notification, so the symptom reads as "the agent doesn't know it's in the channel" when
  the agent knows perfectly well and the *directory* is what's wrong. Hit live 2026-08-11.

  Needs no human secret — the record is signed by the agent's own key — so unlike `attest` this runs
  unattended. `doctor` now compares live membership against the published record and points at the
  fix when they diverge.
- **`doctor`: directory-freshness check per agent**, so this class of staleness stops being invisible.

- **A channel name containing a space no longer corrupts the directory record.** The record builder
  split names on all whitespace, so a channel called `jira management` became two entries — which
  desynchronizes `channels[]` from `channel_ids[]`. Desktop pairs those two arrays *positionally*, so
  the misalignment is worse than a stale record: name *i* stops describing id *i*, and the Activity
  panel would open the wrong channel. Now splits on newlines only, and asserts the two arrays are the
  same length before publishing.

### Changed
- The kind:10100 publisher moved to `lib/directory-record.sh`, shared by `attest` and
  `sync-directory`. A partial or short record silently un-mentions an agent, so there must be exactly
  one implementation for it to drift out of.

## 0.4.0 — 2026-08-11

### Added
- **`cortex attest [<name>...]` — owner attestation + the relay directory record.** Provisioning an
  agent is not the same as having a working one, and this step cannot live in `provision`: minting an
  attestation requires the OWNER's secret key, which an operator must never hold. Skipping it is
  invisible — the agent provisions, replies to mentions, and looks completely healthy, while
  `users.agent_owner_pubkey` stays NULL (so the relay drops every kind:24200 observer frame and the
  client's Activity panel is permanently empty) and no kind:10100 record exists (so the agent is
  missing from @mention autocomplete). Nothing logs either omission. Hit live 2026-08-10 on the 13th
  agent of an otherwise healthy instance.
  Guards the irreversible case: `users.agent_owner_pubkey` is **first-mint-wins and immutable**
  (buzz-db updates it only `WHERE agent_owner_pubkey IS NULL`), so attesting to the wrong identity is
  permanent for that keypair and re-attesting is a silent no-op. The command derives the pubkey from
  the pasted secret and refuses unless it matches `AGENT_OWNER`.
- **`cortex sync-mcp-auth [<server>...]` — MCP OAuth for every agent.** `cursor-agent` stores MCP auth
  **per project**, keyed by a slug of the CWD. Each agent runs from its own dir, so a human's
  `cursor-agent mcp login <server>` authenticates their shell and **not one agent** — every agent then
  reports `requires_authentication` for a server that is demonstrably logged in, which reads as a
  broken login rather than a scoping rule. The stored bundle is self-contained, so one consent covers
  every agent.
- **`cortex install-mcp-plugin` — an operator MCP surface inside the vault.** Installs
  `cortex_list_agents`, `cortex_agent_readiness`, `cortex_doctor`, `cortex_start_agent`, and
  `cortex_sync_mcp_auth` into `<vault>/_meta/mcp-plugins/`, where synapse-mcp discovers them by
  convention. A principal agent that can author an agent note but cannot see operator state will
  report success after step 1 of 4. Attestation is deliberately **not** exposed — it needs the owner's
  secret — but `cortex_agent_readiness` reports whether it has been done.
- **`doctor` now reports per-agent MCP auth**, alongside the attestation check it already ran.
  Completes the set of post-provision gaps that fail silently.
- **`opencode` (sst/opencode) as an ACP runtime.** `opencode acp` is the official
  Agent Client Protocol server subcommand — same hook the other runtimes expose, same
  JSON-RPC over stdio. Set `BUZZ_SYNAPSE_AGENT_COMMAND=opencode` (global default) or
  `AGENT_<name>_RUNTIME=opencode` per agent. The provider is whatever opencode is
  configured with in `~/.config/opencode/opencode.json` (Anthropic, OpenAI, Ollama,
  custom endpoints, etc.) — no provider-specific code in Cortex. `doctor` probes
  `opencode acp --help` and `opencode --version`. Requires opencode ≥ 1.1.

### Fixed
- **Corrected two claims in `provision-agent.sh` that were wrong and actively misleading.** It said
  (a) attesting costs you the mention picker, so default it OFF, and (b) "observer frames do NOT need
  this — cortex passes `--agent-owner`". Following that guidance is how you get an agent that chats
  normally with a permanently empty Activity panel. (a) was a **client** bug (block/buzz#4489), not a
  property of attestation. (b) is false: `--agent-owner` sets only the agent's LOCAL belief about its
  owner — enough to gate who it replies to — and mints no attestation, so the relay's record (a
  different source of truth) stays NULL. Attestation is **required** for an observable agent, not a
  cosmetic label.

### Changed
- `agent_env()` / `buzz_cli()` moved to `config.sh` — every command that touches a keyfile or the Buzz
  CLI needs them, not just `factory.sh`. `run-agent.sh` exports `CORTEX_INSTANCE` into the per-agent
  MCP wrapper so the operator plugin can resolve its instance.
- `peerDependencies` on `@eborja/synapse` bumped to `^0.8.0` — the documented add-an-agent flow uses
  `synapse new agent --addressable`, which does not exist before 0.8.0.

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
