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
  # macOS sed takes `sed -i '' script file`; GNU sed reads it as `-i <ext> <script> <file>`
  # and fails on Linux/CachyOS. Portable in-place edit via temp file.
  _tmp="$(mktemp)"; sed "s|^BUZZ_RELAY_URL=.*|BUZZ_RELAY_URL=$AGENT_RELAY|" "$KEYFILE" > "$_tmp"; mv "$_tmp" "$KEYFILE"
else
  printf 'BUZZ_RELAY_URL=%s\n' "$AGENT_RELAY" >>"$KEYFILE"
fi
chmod 600 "$KEYFILE"
echo "  relay url: $AGENT_RELAY"

# ── NIP-OA owner attestation (OPT-IN — default OFF) ────────────────────────────────
# A client renders "managed by <owner>" from an `["auth", owner_pk, conditions, sig]` tag in the
# agent's kind:0 profile — without it the agent reads as unowned ("owner unavailable"). The tag is a
# signature by the OWNER over the agent's pubkey, so only the owner's secret can mint it; an agent
# cannot declare its own owner (self-attestation is rejected outright by the SDK).
#
# WHY IT DEFAULTS OFF — the label costs you the mention picker.
# Buzz Desktop derives `is_agent` from the presence of an owner attestation
# (`desktop/src-tauri/src/nostr_convert.rs`: `is_agent: owner_pubkey.is_some()`), and its mention
# autocomplete then DROPS any `is_agent` identity that is not in Desktop's OWN managed-agent list
# (`desktop/src/features/messages/lib/useMentions.ts` → `isAgentIdentityInManagedList`). That gate
# runs BEFORE the relay-directory (kind:10100) invocability check, so an externally-run agent — which
# Desktop never manages — becomes un-@mentionable the moment it is attested, no matter how correctly
# it is registered. Verified live 2026-08-04.
#
# So: attest only if you value the ownership label MORE than mentioning the agent from a Buzz client.
# Observer frames do NOT need this — cortex passes `--agent-owner` explicitly (see run-agent.sh), and
# BUZZ_AUTH_TAG would merely override it (buzz-acp resolves the tag with priority over the flag).
# Empty conditions = unrestricted, matching what the relay itself issues.
AUTH_EXAMPLE="$BUZZ_REPO/target/release/examples/compute_auth_tag"
[ -x "$AUTH_EXAMPLE" ] || AUTH_EXAMPLE="$BUZZ_REPO/target/debug/examples/compute_auth_tag"
if [ "${OWNER_ATTESTATION:-0}" != "1" ]; then
  : # opt-in only; set OWNER_ATTESTATION=1 in factory.config to mint one
elif grep -q '^BUZZ_AUTH_TAG=' "$KEYFILE" 2>/dev/null; then
  echo "  owner attestation: already signed"
elif [ -x "$AUTH_EXAMPLE" ]; then
  OWNER_SEC_HEX="$(sed -n 's/^SEC=//p' "$BUZZ_OWNER_ENV" | head -1)"
  if [ -n "$OWNER_SEC_HEX" ] && TAG="$("$AUTH_EXAMPLE" "$OWNER_SEC_HEX" "$AGENT_PUB" "" 2>/dev/null)" && [ -n "$TAG" ]; then
    # SINGLE-QUOTE it. The tag is JSON, and this file is `.`-sourced: an unquoted value loses every
    # `"` to shell quote-removal, so buzz-acp receives `[auth,<pk>,,<sig>]` and rejects it with
    # "invalid JSON: expected value at line 1 column 2" — then silently falls back to an unowned agent.
    printf "BUZZ_AUTH_TAG='%s'\n" "$TAG" >>"$KEYFILE"; chmod 600 "$KEYFILE"
    echo "  owner attestation: signed by $(sed -n 's/^PUB=//p' "$BUZZ_OWNER_ENV" | head -1 | cut -c1-16)…"
  else
    echo "  owner attestation: SKIPPED (could not sign — agent will read as unowned)" >&2
  fi
else
  echo "  owner attestation: SKIPPED (no compute_auth_tag in $BUZZ_REPO — build it to attest ownership)" >&2
fi
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
