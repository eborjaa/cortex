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

# ── NIP-OA owner attestation (OPT-IN here; the real path is `cortex attest`) ──────
# A client renders "managed by <owner>" from an `["auth", owner_pk, conditions, sig]` tag in the
# agent's kind:0 profile — without it the agent reads as unowned ("owner unavailable"). The tag is a
# signature by the OWNER over the agent's pubkey, so only the owner's secret can mint it; an agent
# cannot declare its own owner (self-attestation is rejected outright by the SDK).
# Empty conditions = unrestricted, matching what the relay itself issues.
#
# ── CORRECTION 2026-08-10: two claims that used to live here were WRONG ───────────
# This block previously said (a) attesting costs you the mention picker, so default it OFF, and
# (b) "Observer frames do NOT need this — cortex passes `--agent-owner` explicitly." Both are false,
# and together they produced an agent that chats normally with a permanently empty Activity panel:
#
# (a) The mention-picker breakage was a CLIENT bug (block/buzz#4489), not a property of attestation:
#     Desktop derived `is_agent` from the attestation and then dropped any `is_agent` identity absent
#     from its OWN managed list, which an externally-run agent can never join. Fixed in
#     desktop/src/features/messages/lib/useMentions.ts — channel members are no longer filtered by
#     the managed-agent list. With a patched client, attesting costs nothing.
#
# (b) `--agent-owner` sets only the agent's LOCAL belief about its owner — enough to gate who it
#     replies to. It mints NO attestation, so `users.agent_owner_pubkey` stays NULL, and NIP-AO makes
#     the relay drop every kind:24200 observer frame for an agent whose owner it cannot verify.
#     Local belief and the relay's record are DIFFERENT sources of truth; only the attestation writes
#     the second one.
#
# So: attestation is REQUIRED for an observable agent, not a cosmetic label. It stays opt-in *here*
# only because provisioning must never hold the owner's secret key — run `cortex attest [<name>]`,
# which also publishes the kind:10100 directory record that @mentions and the observer subscription
# both depend on.
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

# ── Ownership sanity check — the relay's record is PERMANENT ────────────────────
# `users.agent_owner_pubkey` is FIRST-MINT-WINS and immutable: buzz-db/src/user.rs sets it only
# `WHERE agent_owner_pubkey IS NULL` ("first-mint-wins ... its value cannot change under us").
# NIP-AO then makes every observer frame conditional on it — "Relay MUST verify is_agent_owner(agent,
# owner)" — so an agent whose relay-recorded owner is not the identity you WATCH from publishes
# telemetry that the relay silently discards. The client's Activity panel shows "No ACP activity yet"
# forever, with no error on either side, and RE-ATTESTING CANNOT FIX IT: the profile updates and the
# relay column does not. The only remedy is a new keypair.
#
# Cost us hours on 2026-08-07: a throwaway attestation signed by the CLI owner permanently bound all
# 12 agents to that identity, after which every correct fix was inert. So: warn LOUDLY the moment the
# relay's record disagrees with AGENT_OWNER, while rotating the key is still cheap.
if [ -n "${AGENT_OWNER:-}" ] && command -v docker >/dev/null 2>&1; then
  recorded="$(docker exec buzz-postgres psql -U buzz -d buzz -tAc \
    "SELECT COALESCE(encode(agent_owner_pubkey,'hex'),'') FROM users WHERE pubkey=decode('$AGENT_PUB','hex');" \
    2>/dev/null | tr -d '[:space:]')" || recorded=""
  if [ -n "$recorded" ] && [ "$recorded" != "$AGENT_OWNER" ]; then
    echo "  !! OWNERSHIP MISMATCH — the relay permanently records this agent's owner as" >&2
    echo "     ${recorded:0:16}… but AGENT_OWNER (the identity you watch from) is ${AGENT_OWNER:0:16}…" >&2
    echo "     Observer frames WILL be dropped and the Activity panel will stay empty." >&2
    echo "     agent_owner_pubkey is immutable — fix by rotating this agent's key:" >&2
    echo "       cortex stop $NAME && rm ~/.config/buzz/agents/$NAME.env && cortex provision $NAME" >&2
    echo "     then attest with the WATCHED identity BEFORE the agent authenticates again." >&2
  fi
fi

[ -f "$BUZZ_OWNER_ENV" ] || { echo "provision FAIL: owner env missing at $BUZZ_OWNER_ENV — set BUZZ_OWNER_ENV in factory.config" >&2; exit 1; }

export BUZZ_RELAY_URL="${BUZZ_RELAY_HTTP:-http://localhost:3000}"
export BUZZ_PRIVATE_KEY="$AGENT_SEC"
# EXPORT the attestation before publishing the profile. The tag above was appended to $KEYFILE, not
# exported, so `users set-profile` ran without it and published a kind:0 carrying NO auth tag — the
# attestation existed on disk but never reached the profile. That silently breaks the consumer that
# needs it: a client derives "managed by <owner>" AND its observer-frame decrypt set from the kind:0
# auth tag (buzz-acp's own profile_event_is_agent() looks for exactly this 4-element tag), so the
# Activity panel stayed empty with no error anywhere. Verified against the relay DB 2026-08-07:
# kind:0 tags were `[]` until the tag was exported, then `[["auth",<owner>,"",<sig>]]`.
# Re-read from the keyfile so this works on the already-attested path too.
if grep -q '^BUZZ_AUTH_TAG=' "$KEYFILE" 2>/dev/null; then
  BUZZ_AUTH_TAG="$(sed -n "s/^BUZZ_AUTH_TAG='\(.*\)'$/\1/p" "$KEYFILE" | head -1)"
  export BUZZ_AUTH_TAG
fi
"$BUZZ_CLI" users set-profile --name "$NAME" --about "Synapse agent ($NAME)." >/dev/null
echo "  profile: display name '$NAME'${BUZZ_AUTH_TAG:+ (+ owner attestation)}"
unset BUZZ_AUTH_TAG   # must NOT leak into the owner-signed channel ops below (self-attestation error)

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
