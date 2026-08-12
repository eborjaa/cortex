#!/usr/bin/env bash
# config.sh — locate + source a Cortex instance's factory.config. Sourced by the other lib scripts.
#
# An "instance" is a directory holding factory.config (+ logs/, prompts/, .cortex/). Resolution:
#   1. $CORTEX_INSTANCE if set (LaunchAgents pass it explicitly)
#   2. an ancestor of $PWD that contains factory.config
# Fails loudly — never guesses ([[rule-synapse-fail-loudly]]).

# Per-agent settings use FLAT variables (AGENT_<name>_HUB=…), not associative arrays — macOS ships
# bash 3.2, which has no `declare -A`. Accessors below read them by indirect expansion.

cortex_find_instance() {
  if [ -n "${CORTEX_INSTANCE:-}" ]; then
    [ -f "$CORTEX_INSTANCE/factory.config" ] && { echo "$CORTEX_INSTANCE"; return 0; }
    echo "cortex: CORTEX_INSTANCE=$CORTEX_INSTANCE has no factory.config" >&2; return 1
  fi
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -f "$d/factory.config" ] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  echo "cortex: no factory.config found (run inside an instance dir, or set CORTEX_INSTANCE)." >&2
  return 1
}

# The vault's agent definitions declare their own capabilities (synapse decision-0008):
#   addressable: true — holds a Buzz identity; can be @mentioned and replies in-thread
#   autonomous:  true — runs on its own clock, unprompted
# The PACKAGE owns the roster: we derive who to provision and run from `addressable`, so adding a
# watchable agent is a vault edit, not a harness edit. Prints one bare agent name per line.
cortex_agents_with_flag() {
  local flag="$1" f id
  for f in "$SYNAPSE_VAULT"/agents/agent-*.md; do
    [ -e "$f" ] || return 0                    # glob didn't match — no agents
    grep -qE "^${flag}:[[:space:]]*true[[:space:]]*$" "$f" || continue
    id="$(basename "$f" .md)"; echo "${id#agent-}"
  done
}
cortex_addressable_agents() { cortex_agents_with_flag addressable; }
cortex_autonomous_agents()  { cortex_agents_with_flag autonomous; }

# Load the instance: sets INSTANCE and sources its factory.config. Applies safe defaults after.
cortex_load() {
  INSTANCE="$(cortex_find_instance)" || exit 1
  # shellcheck disable=SC1090,SC1091
  . "$INSTANCE/factory.config"
  : "${SYNAPSE_VAULT:?factory.config must set SYNAPSE_VAULT}"
  : "${BUZZ_REPO:=$HOME/synapse/buzz}"
  : "${BUZZ_DEFAULT_CHANNEL_NAME:=general}"
  : "${BUZZ_SYNAPSE_AGENT_COMMAND:=claude-agent-acp}"
  : "${SYNAPSE_MCP_SURFACE:=full}"
  : "${PROMPT_SOURCE:=render}"
  # The hub an agent briefs on when AGENT_<name>_HUB is unset. `hub-synapse` is the reference vault's
  # root hub, but a consumer vault names its hubs whatever it likes (this REL vault uses `moc-*`), and
  # rendering against a hub that does not exist fails the launch. Override in factory.config.
  : "${DEFAULT_HUB:=hub-synapse}"
  # A standing agent is long-lived and answers on its own initiative, so its model choice is a
  # STANDING cost, not a per-call one. Default to the cheaper mid-tier; override globally with MODEL=
  # or per agent with AGENT_<name>_MODEL (e.g. a reasoning-heavy steward). MODEL=default defers to
  # whatever the ACP runtime picks. `buzz-acp models --agent-command <runtime>` lists valid ids.
  : "${MODEL:=sonnet}"
  # Publish encrypted ACP observer frames so a client can render the agent's live work (the Activity
  # panel). Without this the panel stays empty even while the agent runs. Set RELAY_OBSERVER=0 to mute.
  : "${RELAY_OBSERVER:=1}"
  # Observer frames are encrypted TO THE OWNER, so `--relay-observer` alone publishes nothing: buzz-acp
  # warns "no agent owner was resolved at startup; observer frames will not be published" and carries on.
  # Default the owner to the identity in BUZZ_OWNER_ENV. Override AGENT_OWNER when you watch from a
  # DIFFERENT client identity than the one doing admin ops (a desktop app vs the CLI are separate
  # pubkeys) — frames encrypted to one cannot be read by the other.
  if [ -z "${AGENT_OWNER:-}" ] && [ -n "${BUZZ_OWNER_ENV:-}" ] && [ -f "$BUZZ_OWNER_ENV" ]; then
    AGENT_OWNER="$(sed -n 's/^PUB=//p' "$BUZZ_OWNER_ENV" | head -1)"
  fi
  : "${AGENT_OWNER:=}"
  # STANDING — the agents this instance provisions and runs. DERIVED from the vault's
  # `addressable: true` roster; set it in factory.config only to deliberately override (a subset for
  # a test instance, say). An explicit-but-empty STANDING= means "derive", not "run nothing".
  if [ -z "${STANDING+x}" ] || [ "${#STANDING[@]}" -eq 0 ] || [ -z "${STANDING[0]}" ]; then
    STANDING=()
    while IFS= read -r _a; do [ -n "$_a" ] && STANDING+=("$_a"); done <<EOF
$(cortex_addressable_agents)
EOF
    [ "${#STANDING[@]}" -gt 0 ] || echo "cortex: no agent in $SYNAPSE_VAULT/agents declares 'addressable: true'" >&2
  fi
  cortex_load_secrets
  export SYNAPSE_VAULT BUZZ_REPO
}

# Load credentials the VAULT's own recipes need at run time (Zephyr tokens, automation-user
# passwords, …) from dotenv files, exporting every key.
#
# Why this exists: a standing agent shells out for real work — it even REPLIES by running
# `buzz messages send` (see run-agent.sh) — but buzz-acp receives its identity as a CLI flag, so the
# shell running the agent's tools inherits nothing. A vault recipe that says
# `curl -H "Authorization: Bearer $ZEPHYR_TOKEN" …` therefore ran with an EMPTY token and failed with
# a 401 that looks like a broken recipe rather than a missing credential.
#
# Precedence (later wins, so an instance can override a vault-wide default):
#   1. $SYNAPSE_VAULT/.env   — vault-wide (shared by every instance driving this vault)
#   2. $INSTANCE/.env        — this instance only
# Both are gitignored by convention; secrets never live in factory.config.
#
# `set -a` exports each assignment, so the values survive into run-agent.sh's `exec env` (which
# preserves the ambient environment) and into the per-agent MCP wrapper it spawns.
cortex_load_secrets() {
  local f
  for f in "$SYNAPSE_VAULT/.env" "$INSTANCE/.env"; do
    [ -f "$f" ] || continue
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  done
}

# Per-agent accessors: read AGENT_<name>_<FIELD> (flat vars), else fall through to the default.
# Agent names are sanitized to a valid var suffix so hyphenated names don't break the lookup.
_agent_var() { local key; key="$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')"; echo "AGENT_${key}_$2"; }
_agent_get() { local v d; v="$(_agent_var "$1" "$2")"; eval "d=\${$v:-}"; echo "$d"; }
agent_hub()         { local d; d="$(_agent_get "$1" HUB)";     echo "${d:-$DEFAULT_HUB}"; }
agent_profile()     { local d; d="$(_agent_get "$1" PROFILE)"; echo "${d:-standard}"; }
agent_surface()     { local d; d="$(_agent_get "$1" SURFACE)"; echo "${d:-$SYNAPSE_MCP_SURFACE}"; }
agent_runtime_for() { local d; d="$(_agent_get "$1" RUNTIME)"; echo "${d:-$BUZZ_SYNAPSE_AGENT_COMMAND}"; }
agent_model()       { local d; d="$(_agent_get "$1" MODEL)";   echo "${d:-$MODEL}"; }

# Extra environment for THIS agent's MCP server, as a ';'-separated KEY=VALUE list. Emitted into the
# per-agent MCP wrapper by run-agent.sh, so a vault plugin can be configured per agent.
#
# This exists because a surface is a coarse dial: synapse registers its handover tools on `full` only,
# so an agent that merely needs handovers must run `full` — and would inherit every other `full`
# capability (e.g. a vault plugin's write tools) as an accident of that one requirement. Per-agent MCP
# env lets the instance narrow a plugin without demoting the agent off `full`. Example:
#   AGENT_qa_lead_MCP_ENV="ZEPHYR_MCP_READONLY=1"
agent_mcp_env()     { _agent_get "$1" MCP_ENV; }
# Parallel worker subprocesses for ONE agent identity (buzz-acp --agents, 1..32).
#
# One identity, N workers: the agent keeps a single pubkey, profile and Activity panel, but can hold
# turns in N channels at once. With the default 1, a mention in channel B waits for channel A's turn
# to finish — up to --max-turn-duration of silence after the 👀 reaction, which reads as the agent
# ignoring you rather than queueing (buzz-acp requeues, it does not drop).
#
# COST: each worker is a full runtime subprocess plus its own MCP server, and they all share ONE
# working directory and git identity. Two workers doing git in the same checkout is a real hazard —
# see the vault's rule-one-writer-per-worktree. Raise this for agents whose parallel work is mostly
# read-only; prefer per-worker checkouts before going high.
agent_workers()     { local d; d="$(_agent_get "$1" WORKERS)"; echo "${d:-${BUZZ_ACP_AGENTS:-1}}"; }

# ── Turn budget ─────────────────────────────────────────────────────────────────
# TWO independent timers, and the LOWER one always wins — so raising only the wall-clock cap
# accomplishes nothing:
#
#   MAX_TURN — absolute wall-clock cap per turn ("how long may a turn take").
#   IDLE     — max seconds of SILENCE, reset by any agent stdout. This is the one that surprises
#              people: a long step that prints nothing (a test suite, a build, a sleep) looks
#              identical to a hung agent, so a low idle timeout kills healthy long work no matter
#              how large MAX_TURN is. Seen live 2026-08-11 on a real workflow:
#                WARN idle timeout (300s) — no agent activity
#                WARN cancelling session 33f0378c…
#
# Keep IDLE strictly BELOW MAX_TURN: if they are equal the idle timer can never fire first and hang
# detection is gone entirely, leaving the wall-clock cap as the only backstop.
#
# A long turn OCCUPIES A WORKER for its whole duration, so this interacts with AGENT_<name>_WORKERS —
# N long turns fill the pool and further mentions queue (👀 then silence) until one frees up.
agent_idle_timeout() { local d; d="$(_agent_get "$1" IDLE_TIMEOUT)"; echo "${d:-${BUZZ_ACP_IDLE_TIMEOUT:-300}}"; }
agent_max_turn()     { local d; d="$(_agent_get "$1" MAX_TURN)";     echo "${d:-${BUZZ_ACP_MAX_TURN_DURATION:-600}}"; }

# The consumer vault's installed CLIs (the engine + MCP server ship with @eborja/synapse).
synapse_bin()     { echo "$SYNAPSE_VAULT/node_modules/.bin/synapse"; }
synapse_mcp_bin() { echo "$SYNAPSE_VAULT/node_modules/.bin/synapse-mcp"; }

# An agent's keyfile: PUB / SEC / relay URL / BUZZ_AUTH_TAG. Every command that provisions, attests,
# or runs an agent reads it, so it belongs here rather than in any one command.
agent_env()  { echo "$HOME/.config/buzz/agents/$1.env"; }
# The separately-installed Buzz CLI. Debug build wins when present — that is what a developer
# iterating on Buzz has just built, and silently preferring a stale release binary hides their work.
buzz_cli()   { local c="$BUZZ_REPO/target/debug/buzz"; [ -x "$c" ] || c="$BUZZ_REPO/target/release/buzz"; echo "$c"; }
