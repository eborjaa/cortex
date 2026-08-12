#!/usr/bin/env bash
# attest-agent.sh — mint the owner attestation + relay-directory record for standing agents.
#
# WHY THIS IS A FIRST-CLASS COMMAND
# `cortex provision` cannot do this: minting an attestation requires the OWNER's SECRET key, which an
# operator must never hold. So it is a deliberate human step — but skipping it is invisible. The
# agent provisions, replies to mentions, and looks completely healthy, while:
#   * users.agent_owner_pubkey stays NULL, so the relay drops every kind:24200 observer frame and the
#     client's Activity panel is permanently empty; and
#   * no kind:10100 record exists, so the agent is missing from the client's agent directory — which
#     gates both @mention autocomplete and the observer subscription.
# Nothing logs either omission. Hit live 2026-08-10 on the 13th agent of a working instance.
#
# WHAT IT SIGNS
# A NIP-OA tag ["auth", <owner_pubkey>, <conditions>, <sig>] — the owner signing over the AGENT's
# pubkey. Only the owner's secret can mint it; self-attestation is rejected by the SDK outright.
# Your secret is read with `read -rs`, used by the local compute_auth_tag binary, and never written
# to disk or echoed. What lands on the relay is the tag: public data.
#
# ORDER MATTERS — users.agent_owner_pubkey is FIRST-MINT-WINS and IMMUTABLE
# buzz-db/src/user.rs sets it only `WHERE agent_owner_pubkey IS NULL`. Attesting a key to the WRONG
# owner is therefore permanent for that keypair, and re-attesting is a silent no-op — the only
# recovery is new keys. Attest with the identity you will actually watch from, the first time.
#
# Usage (from an instance dir, or with CORTEX_INSTANCE set):
#   cortex attest                 # every standing agent
#   cortex attest bug-filer       # only these (leaves other agents' in-flight turns alone)
set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$LIB/config.sh"
cortex_load
# shellcheck disable=SC1091
. "$LIB/directory-record.sh"

BUZZ="$(buzz_cli)"
AUTH="$BUZZ_REPO/target/release/examples/compute_auth_tag"
SIGN="$BUZZ_REPO/target/release/examples/sign_event"
RELAY_HTTP="${BUZZ_RELAY_HTTP:-http://localhost:3000}"

for b in "$AUTH" "$SIGN"; do
  [ -x "$b" ] || { echo "cortex attest: missing $b
Build it in your Buzz checkout:  cargo build --release -p buzz-sdk --examples" >&2; exit 1; }
done

if [ -z "${AGENT_OWNER:-}" ]; then
  echo "cortex attest: AGENT_OWNER is unset in factory.config — set it to the pubkey of the identity
you watch agents from (the one whose client should show their activity)." >&2
  exit 1
fi

# Resolve targets BEFORE prompting, so a mistyped name fails fast rather than after a secret is typed.
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
  for a in "${TARGETS[@]}"; do
    [ -f "$(agent_env "$a")" ] || { echo "cortex attest: no keyfile for '$a' — run 'cortex provision $a' first" >&2; exit 1; }
  done
else
  TARGETS=("${STANDING[@]}")
fi
echo "targets: ${TARGETS[*]}"

printf 'Paste the OWNER secret key for %s… (nsec or hex) — input hidden: ' "${AGENT_OWNER:0:16}"
read -rs OWNER_SEC
printf '\n'
[ -n "$OWNER_SEC" ] || { echo "no key entered — aborting" >&2; exit 1; }

# Derive-and-verify before touching anything: sign a throwaway tag and read the owner pubkey back out
# of it. Guards against pasting a DIFFERENT identity, which would be permanent (see immutability note).
probe_pub="$(sed -n 's/^PUB=//p' "$(agent_env "${TARGETS[0]}")" | head -1)"
probe_tag="$("$AUTH" "$OWNER_SEC" "$probe_pub" "" 2>/dev/null)" || {
  echo "could not sign with that key — is it a valid nsec/hex secret?" >&2; exit 1; }
derived="$(printf '%s' "$probe_tag" | sed -n 's/^\["auth","\([0-9a-f]\{64\}\)".*/\1/p')"
if [ "$derived" != "$AGENT_OWNER" ]; then
  echo "REFUSING: that key derives ${derived:0:16}… but AGENT_OWNER is ${AGENT_OWNER:0:16}…
Attesting to the wrong identity is PERMANENT for these keypairs." >&2
  exit 1
fi
echo "verified: key matches AGENT_OWNER ${derived:0:16}…"

# The kind:10100 directory record comes from lib/directory-record.sh — shared with
# `cortex sync-directory`, which refreshes it after any membership change. One implementation:
# a partial or short record silently un-mentions the agent, so it must not drift between callers.

count=0
for name in "${TARGETS[@]}"; do
  f="$(agent_env "$name")"
  agent_pub="$(sed -n 's/^PUB=//p' "$f" | head -1)"
  agent_sec="$(sed -n 's/^SEC=//p' "$f" | head -1)"
  [ -n "$agent_pub" ] && [ -n "$agent_sec" ] || { echo "  ! $name: keyfile incomplete" >&2; continue; }

  tag="$("$AUTH" "$OWNER_SEC" "$agent_pub" "")" || { echo "  ! $name: signing failed" >&2; continue; }

  # SINGLE-QUOTE the value. Keyfiles are `.`-sourced, and the tag is JSON: unquoted, shell
  # quote-removal strips every `"`, buzz-acp receives [auth,<pk>,,<sig>], rejects it as invalid JSON,
  # and falls back to an UNOWNED agent — the exact failure this command exists to prevent.
  tmp="$(mktemp)"
  grep -v '^BUZZ_AUTH_TAG=' "$f" > "$tmp" || true
  printf "BUZZ_AUTH_TAG='%s'\n" "$tag" >> "$tmp"
  mv "$tmp" "$f"; chmod 600 "$f"

  # REPUBLISH kind:0 with the tag EXPORTED. Writing the keyfile is not enough, and neither is a
  # restart: buzz-acp uses the tag for its relay AUTH handshake, but the attestation a CLIENT reads
  # lives on the profile. Verified against the relay DB — kind:0 tags stayed `[]` across restarts and
  # only became [["auth",…]] once the profile was re-published with BUZZ_AUTH_TAG in the environment.
  if ! BUZZ_PRIVATE_KEY="$agent_sec" BUZZ_RELAY_URL="$RELAY_HTTP" BUZZ_AUTH_TAG="$tag" \
       "$BUZZ" users set-profile --name "$name" --about "Synapse agent ($name)." >/dev/null 2>&1; then
    echo "  ! $name: profile republish failed — activity will stay invisible for this agent" >&2
    continue
  fi
  echo "  attested + profile published: $name"
  publish_directory_record "$name" "$agent_pub" "$agent_sec" || true
  count=$((count + 1))
done

unset OWNER_SEC
echo
echo "$count agent(s) attested."
# The restart is required, not precautionary: buzz-acp resolves the owner ONCE at startup and caches
# it for the process lifetime, so a running agent keeps its pre-attestation owner until recycled.
if [ "$#" -gt 0 ]; then
  echo "Restart just these (leaves other agents' in-flight turns alone):"
  echo "  cortex restart $*"
else
  echo "Restart so the new owner is picked up:  cortex restart all"
fi
