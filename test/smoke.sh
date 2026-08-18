#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cortex-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

node --check "$ROOT/bin/cortex.mjs"
node --check "$ROOT/lib/init.mjs"
node --check "$ROOT/templates/mcp-plugins/cortex.mjs"
bash -n "$ROOT"/lib/*.sh
shellcheck -S warning "$ROOT"/lib/*.sh >/dev/null

XDG_CONFIG_HOME="$TMP/config" node "$ROOT/bin/cortex.mjs" init "$TMP/instance" --write >/dev/null
printf '\nSTANDING=(smoke)\n' >>"$TMP/instance/factory.config"

# Claude keeps Cortex's existing model default; OpenCode must defer to opencode.json even when the
# instance or agent has a stale Claude-style model configured.
CORTEX_INSTANCE="$TMP/instance" ROOT="$ROOT" bash -c \
  '. "$ROOT/lib/config.sh"; cortex_load; test "$(agent_model smoke)" = sonnet'
CORTEX_INSTANCE="$TMP/instance" ROOT="$ROOT" BUZZ_SYNAPSE_AGENT_COMMAND=opencode bash -c \
  '. "$ROOT/lib/config.sh"; cortex_load; test "$(agent_runtime_for smoke)" = opencode; test "$(agent_model smoke)" = default'
printf '\nAGENT_smoke_RUNTIME="opencode"\nAGENT_smoke_MODEL="anthropic/ignored"\n' >>"$TMP/instance/factory.config"
CORTEX_INSTANCE="$TMP/instance" ROOT="$ROOT" bash -c \
  '. "$ROOT/lib/config.sh"; cortex_load; test "$(agent_runtime_for smoke)" = opencode; test "$(agent_model smoke)" = default'

if [ "$(uname -s)" = "Linux" ] && command -v systemctl >/dev/null 2>&1; then
  CORTEX_INSTANCE="$TMP/instance" XDG_CONFIG_HOME="$TMP/config" \
    node "$ROOT/bin/cortex.mjs" install-systemd >/dev/null
  for unit in com.cortex-relay.service com.cortex-smoke.service; do
    test -f "$TMP/instance/systemd/$unit"
    if command -v systemd-analyze >/dev/null 2>&1; then
      systemd-analyze verify "$TMP/instance/systemd/$unit"
    fi
  done
fi

printf 'smoke tests passed\n'
