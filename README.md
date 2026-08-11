# 🧩 Cortex — run standing AI agents on your Synapse vault

> **The operator for Synapse standing agents.** Scaffold, provision, run, and health-check
> role-based agents that brief from a [Synapse](https://github.com/eborjaa/synapse) vault and talk
> over [Block's Buzz](https://github.com/block/buzz) — with one command each.
> Runs entirely on hardware you control.

---

## What it solves

You have a Synapse vault (your knowledge graph) and you want to **@mention agents in chat and have
them answer from it** — an `oracle` that reads, a `curator` that maintains. Making that real means a
pile of plumbing: a relay to run, agent identities to mint and register, always-on processes that
bridge chat → Claude → your Synapse MCP tools, keep-alive so they survive a reboot, and a health
check for when something breaks.

Cortex **is that plumbing, packaged.** It's the control room: `init` a workspace, `provision` the
agents, `start` them, `doctor` the whole thing — no hand-rolled scripts, no machine-specific paths.

Three layers, clean boundaries:

| Layer | What it is | Who owns it |
|---|---|---|
| **[Synapse](https://github.com/eborjaa/synapse)** | the agents' brain — briefings + MCP tools from your vault | you (`@eborja/synapse`) |
| **Cortex** | the operator — scaffolds, runs, and supervises the agents | this package |
| **[Buzz](https://github.com/block/buzz)** | the chat/relay substrate the agents talk over | Block (you install it) |

**Cortex ships no Buzz code.** It orchestrates a Buzz you install and build yourself (Apache-2.0);
see [NOTICE](NOTICE).

---

## 🚀 Quick start

Cortex assumes you've already installed, separately: a built **Buzz** checkout, **Docker** (Buzz's
Postgres + Redis), **`@eborja/synapse`** in your vault, and an ACP runtime (`claude-agent-acp`,
`opencode`, or `cursor-agent`).

```bash
# 1. scaffold an instance (a "control room" — your private config)
npx @eborja/cortex init ~/my-agents --write
cd ~/my-agents
npm install                       # installs the `cortex` CLI

# 2. point it at your world
$EDITOR factory.config            # vault path, Buzz repo, roster, per-agent hubs

# 3. bring the agents up
npx cortex doctor                 # check binaries / relay / agents / MCP
npx cortex provision oracle       # mint keys + register + join the channel (repeat per agent)
npx cortex start all              # launch relay + agents
npx cortex install-launchagents && npx cortex launchd-load   # keep them alive (macOS)
```

Then @mention `oracle` / `curator` in your Buzz channel.

---

## ⚡ Commands

```bash
cortex init [dir] [--write]        # scaffold a new instance
cortex doctor                      # health check (binaries, relay, agents, MCP, per-agent surface)
cortex provision <name>            # mint keys + register on the relay + join the channel
cortex attest [<name>...]          # owner attestation + relay directory record (prompts for the
                                   #   owner secret — required for an OBSERVABLE agent, see below)
cortex sync-mcp-auth [<server>...] # copy your MCP OAuth into each agent's per-CWD project store
cortex start [all|relay|<name>]    # launch
cortex stop  [all|relay|<name>]    # stop (per-agent; won't touch the others)
cortex restart [all|<name>]
cortex install-launchagents        # write ~/Library/LaunchAgents plists for this instance
cortex launchd-load | launchd-unload
cortex test-mcp                    # drive the vault's synapse-mcp and list its tools
cortex status
```

Run inside an instance dir (one holding `factory.config`), or set `CORTEX_INSTANCE`.

---

## ➕ Adding an agent

There is no agent registry to edit: **the roster is derived from the vault.** Any note in
`agents/` with `addressable: true` is a standing agent. The three steps after that all fail
*silently* when skipped — the agent looks healthy while being un-runnable, unobservable, or toolless
— so each one is a command rather than a paragraph you have to remember.

```bash
# 1. author the agent note (or use the synapse_create_agent MCP tool with addressable: true)
synapse new agent <name> --addressable

# 2. provision + run it
cortex start <name>                # mints keys, registers on the relay, joins channels

# 3. make it OBSERVABLE — needs the owner's secret, so a human runs this
cortex attest <name>               # owner attestation + kind:10100 directory record

# 4. give it your MCP logins
cortex sync-mcp-auth               # per-CWD OAuth stores; a human's login does not cover agents

cortex doctor                      # confirms all of the above landed
```

**Why 3 and 4 are separate human steps, and what breaks without them:**

| Skipped | Symptom | Why it's invisible |
|---|---|---|
| `attest` | Agent replies normally, but its **Activity panel is permanently empty** | `--agent-owner` sets only the agent's *local* belief; the relay's `users.agent_owner_pubkey` stays NULL, and NIP-AO makes it drop every observer frame for an agent whose owner it can't verify. Nothing is logged. |
| the kind:10100 record (also done by `attest`) | Agent is missing from **@mention autocomplete** | The client builds its agent directory from kind:10100. Absent = not offered, with no error. |
| `sync-mcp-auth` | Agent reports `requires_authentication` for a server **you already logged into** | MCP auth is stored per *project*, keyed by CWD slug. Each agent runs from its own dir, so your shell's login covers none of them. |

> ⚠️ `users.agent_owner_pubkey` is **first-mint-wins and immutable** (`buzz-db/src/user.rs` updates it
> only `WHERE agent_owner_pubkey IS NULL`). Attesting to the wrong identity is *permanent for that
> keypair* and re-attesting is a silent no-op — the only recovery is new keys. `cortex attest` derives
> the pubkey from the secret you paste and refuses to proceed unless it matches `AGENT_OWNER`.

---

## 🧠 The two features that make it more than a launcher

### Prompts are rendered from the vault, not hand-written

Each agent's system prompt is generated at launch from **`synapse render <agent> <hub> --profile
<p>`** — so *how an agent behaves* is defined in your Synapse vault (its `purpose`, the rules that
bind it, the tools it may use, its domain hub), not duplicated in the harness. Edit the agent note in
the vault; the next launch reflects it. (Set `PROMPT_SOURCE=file` and drop
`prompts/<agent>.system.md` to override.)

### Each agent gets its own MCP surface — read-only *by construction*

Cortex injects a per-agent MCP server pinned to that agent's surface. Run **`oracle` on `standard`**
and it literally cannot see the `synapse_create_*` tools (they exist only on `full`) — the read front
door is read-only because the tools aren't registered, not because a prompt asks nicely. Run
`curator` on `full` for authoring.

```ini
# factory.config
STANDING=(oracle curator)
AGENT_oracle_HUB="hub-projects";  AGENT_oracle_SURFACE="standard"   # read-only
AGENT_curator_HUB="hub-synapse";  AGENT_curator_SURFACE="full"      # authoring
```

---

## ⚙️ How an instance is laid out

`init` creates a **thin, private** consumer of this package:

```
my-agents/
  factory.config     # the one seam: paths, roster, per-agent hub/profile/surface/runtime
  prompts/           # optional hand-written prompt overrides (default: rendered from the vault)
  .cortex/           # generated at launch — rendered prompts + per-agent MCP wrappers (gitignored)
  logs/              # runtime logs (gitignored)
  launchd/           # generated LaunchAgent plists
```

Secrets never live here — agent keys stay in `~/.config/buzz/agents/`. `factory.config`
**hard-assigns** its vault path so a stray exported `$SYNAPSE_VAULT` can't silently redirect the
harness.

---

## 📦 Requirements

- **Node ≥ 22** (matches `@eborja/synapse`).
- **Bash** — works on macOS's default bash 3.2 (no associative arrays used).
- **Buzz** (Block, Apache-2.0) built at `$BUZZ_REPO`, with Docker for its Postgres/Redis.
- **`@eborja/synapse` ≥ 0.4** installed in your vault (provides `synapse` + `synapse-mcp`).
- **An ACP runtime**: `claude-agent-acp` (recommended), `opencode` (sst/opencode ≥ 1.1 — uses whatever provider is configured in `~/.config/opencode/opencode.json`, so Anthropic, OpenAI, Ollama, custom endpoints, etc.), or `cursor-agent`.

---

## 🤝 Contributing

Cortex is generic, de-personalized plumbing — contributions improve the operator, never anyone's
config. See [CONTRIBUTING.md](CONTRIBUTING.md). The bar: `shellcheck` clean, no hardcoded personal
values, bash 3.2 compatible.

## 🙏 Acknowledgments

Built to run [Synapse](https://github.com/eborjaa/synapse) agents over
**[Buzz](https://github.com/block/buzz)** by [Block, Inc.](https://block.xyz) (Apache-2.0). "Buzz"
and "Block" are marks of Block, Inc.; Cortex is an independent, unaffiliated tool. See
[NOTICE](NOTICE).

## License

[MIT](LICENSE) © 2026 Emmanuel Borja.
