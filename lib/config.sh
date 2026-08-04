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

# The consumer vault's installed CLIs (the engine + MCP server ship with @eborja/synapse).
synapse_bin()     { echo "$SYNAPSE_VAULT/node_modules/.bin/synapse"; }
synapse_mcp_bin() { echo "$SYNAPSE_VAULT/node_modules/.bin/synapse-mcp"; }
