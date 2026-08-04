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
  export SYNAPSE_VAULT BUZZ_REPO
}

# Per-agent accessors: read AGENT_<name>_<FIELD> (flat vars), else fall through to the default.
# Agent names are sanitized to a valid var suffix so hyphenated names don't break the lookup.
_agent_var() { local key; key="$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')"; echo "AGENT_${key}_$2"; }
_agent_get() { local v d; v="$(_agent_var "$1" "$2")"; eval "d=\${$v:-}"; echo "$d"; }
agent_hub()         { local d; d="$(_agent_get "$1" HUB)";     echo "${d:-hub-synapse}"; }
agent_profile()     { local d; d="$(_agent_get "$1" PROFILE)"; echo "${d:-standard}"; }
agent_surface()     { local d; d="$(_agent_get "$1" SURFACE)"; echo "${d:-$SYNAPSE_MCP_SURFACE}"; }
agent_runtime_for() { local d; d="$(_agent_get "$1" RUNTIME)"; echo "${d:-$BUZZ_SYNAPSE_AGENT_COMMAND}"; }
agent_model()       { local d; d="$(_agent_get "$1" MODEL)";   echo "${d:-$MODEL}"; }

# The consumer vault's installed CLIs (the engine + MCP server ship with @eborja/synapse).
synapse_bin()     { echo "$SYNAPSE_VAULT/node_modules/.bin/synapse"; }
synapse_mcp_bin() { echo "$SYNAPSE_VAULT/node_modules/.bin/synapse-mcp"; }
