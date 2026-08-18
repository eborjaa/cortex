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
