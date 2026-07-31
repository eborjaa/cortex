#!/usr/bin/env bash
# run-relay.sh — launch the local Buzz relay (Block's binary; user-built). Invoked by `cortex start`
# and by the relay LaunchAgent (CORTEX_INSTANCE passed in the plist).
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$LIB/config.sh"
cortex_load

cd "$BUZZ_REPO"
set -a; [ -f .env ] && . ./.env; set +a
export BUZZ_AUTO_MIGRATE="${BUZZ_AUTO_MIGRATE:-true}"
export BUZZ_GIT_CONFORMANCE_PROBE="${BUZZ_GIT_CONFORMANCE_PROBE:-false}"

BIN="$BUZZ_REPO/target/debug/buzz-relay"; [ -x "$BIN" ] || BIN="$BUZZ_REPO/target/release/buzz-relay"
[ -x "$BIN" ] || { echo "run-relay: buzz-relay not built in $BUZZ_REPO" >&2; exit 1; }

mkdir -p "$INSTANCE/logs"
echo "starting relay · ${BUZZ_BIND_ADDR:-0.0.0.0:3000} · ${RELAY_URL:-ws://localhost:3000}"
exec "$BIN"
