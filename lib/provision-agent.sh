#!/usr/bin/env bash
# provision-agent.sh — mint keys + register on the relay + set display name + join the channel.
# Idempotent. Invoked by `cortex provision <name>` and by `cortex start`.
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$LIB/config.sh"
cortex_load

NAME="${1:?usage: provision-agent.sh <name>}"; NAME="${NAME#agent-}"

BUZZ_CLI="${BUZZ_CLI:-$BUZZ_REPO/target/debug/buzz}"; [ -x "$BUZZ_CLI" ] || BUZZ_CLI="$BUZZ_REPO/target/release/buzz"
ADMIN="$BUZZ_REPO/target/debug/buzz-admin"; [ -x "$ADMIN" ] || ADMIN="$BUZZ_REPO/target/release/buzz-admin"
[ -x "$BUZZ_CLI" ] && [ -x "$ADMIN" ] || { echo "provision: buzz / buzz-admin not built in $BUZZ_REPO" >&2; exit 1; }

KEYDIR="$HOME/.config/buzz/agents"
mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
KEYFILE="$KEYDIR/$NAME.env"

if [ -f "$KEYFILE" ]; then
  # shellcheck disable=SC1090
  . "$KEYFILE"; echo "· $NAME — existing ${PUB:0:16}…"
else
  OUT="$("$ADMIN" generate-key)"
  PUB="$(awk '/Public key:/{print $3}' <<<"$OUT")"
  SEC="$(awk '/Secret key:/{print $3}' <<<"$OUT")"
  [ -n "$PUB" ] && [ -n "$SEC" ] || { echo "provision: keygen failed" >&2; exit 1; }
  printf 'PUB=%s\nSEC=%s\nAGENT=%s\n' "$PUB" "$SEC" "$NAME" >"$KEYFILE"; chmod 600 "$KEYFILE"
  echo "· $NAME — minted ${PUB:0:16}…"
fi
AGENT_PUB="$PUB"; AGENT_SEC="$SEC"

# shellcheck disable=SC1090
[ -f "$HOME/.config/buzz/relay.env" ] && . "$HOME/.config/buzz/relay.env"
ADMIN_RELAY="${BUZZ_RELAY_URL:-ws://localhost:3000}"

# An addressable agent replies by shelling out to `buzz messages send`, which needs BOTH a key and a
# relay URL. The key was already here; the relay URL was not — so a freshly provisioned agent (one with
# no memory of a previous run) could authenticate and still fail to publish, and would GUESS a URL.
# Observed live 2026-08-04: reconciler burned two sends before finding relay.env on its own.
# One file therefore carries everything an agent needs to publish. HTTP form — that is what the CLI wants.
AGENT_RELAY="${BUZZ_RELAY_HTTP:-http://localhost:3000}"
if grep -q '^BUZZ_RELAY_URL=' "$KEYFILE" 2>/dev/null; then
  sed -i '' "s|^BUZZ_RELAY_URL=.*|BUZZ_RELAY_URL=$AGENT_RELAY|" "$KEYFILE"
else
  printf 'BUZZ_RELAY_URL=%s\n' "$AGENT_RELAY" >>"$KEYFILE"
fi
chmod 600 "$KEYFILE"
echo "  relay url: $AGENT_RELAY"
RELAY_SEC="$(grep '^BUZZ_RELAY_PRIVATE_KEY=' "$BUZZ_REPO/.env" 2>/dev/null | cut -d= -f2-)"
[ -n "$RELAY_SEC" ] || { echo "provision: BUZZ_RELAY_PRIVATE_KEY missing in $BUZZ_REPO/.env" >&2; exit 1; }

out=$(RELAY_URL="$ADMIN_RELAY" BUZZ_RELAY_PRIVATE_KEY="$RELAY_SEC" "$ADMIN" add-member --pubkey "$AGENT_PUB" 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then echo "  relay member: ok"
elif echo "$out" | grep -qi already; then echo "  relay member: already"
else echo "provision FAIL relay add-member: $out" >&2; exit 1; fi

[ -f "$BUZZ_OWNER_ENV" ] || { echo "provision FAIL: owner env missing at $BUZZ_OWNER_ENV — set BUZZ_OWNER_ENV in factory.config" >&2; exit 1; }

export BUZZ_RELAY_URL="${BUZZ_RELAY_HTTP:-http://localhost:3000}"
export BUZZ_PRIVATE_KEY="$AGENT_SEC"
"$BUZZ_CLI" users set-profile --name "$NAME" --about "Synapse agent ($NAME)." >/dev/null
echo "  profile: display name '$NAME'"

# shellcheck disable=SC1090
. "$BUZZ_OWNER_ENV"; export BUZZ_PRIVATE_KEY="$SEC"     # owner signs the channel add

CHANNEL="${BUZZ_DEFAULT_CHANNEL:-}"
if [ -z "$CHANNEL" ]; then
  CHANNEL="$("$BUZZ_CLI" channels list | CH="$BUZZ_DEFAULT_CHANNEL_NAME" python3 -c '
import json,os,sys
want=os.environ["CH"]
for c in json.load(sys.stdin):
  if c.get("name")==want: print(c["channel_id"]); break
else:
  sys.stderr.write(f"no #{want} — create it in Buzz Desktop first\n"); sys.exit(1)
')"
fi

out=$("$BUZZ_CLI" channels add-member --channel "$CHANNEL" --pubkey "$AGENT_PUB" --role bot 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then echo "  #$BUZZ_DEFAULT_CHANNEL_NAME: bot member ok"
elif echo "$out" | grep -qiE 'already|duplicate'; then echo "  #$BUZZ_DEFAULT_CHANNEL_NAME: already a member"
else echo "provision FAIL channel add-member: $out" >&2; exit 1; fi

echo "· $NAME ready (relay + profile + #$BUZZ_DEFAULT_CHANNEL_NAME)"
