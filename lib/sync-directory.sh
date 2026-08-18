#!/usr/bin/env bash
# sync-directory.sh — refresh each agent's kind:10100 directory record from LIVE channel membership.
#
# WHY THIS EXISTS
# `channel_ids` in the directory record is a snapshot taken at publish time, and nothing keeps it
# fresh (see lib/directory-record.sh for the full trail). Add an agent to a channel from the Desktop
# member picker and the record still lists the old set, which breaks three client behaviours at once:
#   * the agent's profile shows the wrong channel list / count;
#   * "View activity" cannot resolve the new channel (Desktop reads agentChannelIds from this record);
#   * mention-autocomplete eligibility is evaluated against the stale set.
# The agent itself is unaffected — buzz-acp joins the new channel live off a membership notification —
# so the symptom reads as "the agent doesn't know it's in the channel" when the agent knows perfectly
# well and the DIRECTORY is what's wrong.
#
# Safe to run any time, and unattended: the record is signed by the AGENT's own key, so unlike
# `cortex attest` this needs no human secret. Run it after any channel-membership change.
#
# Usage (from an instance dir, or with CORTEX_INSTANCE set):
#   cortex sync-directory                 # every standing agent
#   cortex sync-directory qa-lead         # only these
set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$LIB/config.sh"
cortex_load
# shellcheck disable=SC1091
. "$LIB/directory-record.sh"

# shellcheck disable=SC2034 # consumed by publish_directory_record in directory-record.sh
BUZZ="$(buzz_cli)"
SIGN="$BUZZ_REPO/target/release/examples/sign_event"
[ -x "$SIGN" ] || SIGN="$BUZZ_REPO/target/debug/examples/sign_event"
# shellcheck disable=SC2034 # consumed by publish_directory_record in directory-record.sh
RELAY_HTTP="${BUZZ_RELAY_HTTP:-http://localhost:3000}"

[ -x "$SIGN" ] || { echo "cortex sync-directory: missing sign_event at $SIGN
Build it in your Buzz checkout:  cargo build --release -p buzz-sdk --examples" >&2; exit 1; }

if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
  for a in "${TARGETS[@]}"; do
    [ -f "$(agent_env "$a")" ] || { echo "cortex sync-directory: no keyfile for '$a' — run 'cortex provision $a' first" >&2; exit 1; }
  done
else
  TARGETS=("${STANDING[@]}")
fi

count=0
for name in "${TARGETS[@]}"; do
  f="$(agent_env "$name")"
  [ -f "$f" ] || { echo "  skip $name (not provisioned)"; continue; }
  pub="$(sed -n 's/^PUB=//p' "$f" | head -1)"
  sec="$(sed -n 's/^SEC=//p' "$f" | head -1)"
  [ -n "$pub" ] && [ -n "$sec" ] || { echo "  ! $name: keyfile incomplete" >&2; continue; }
  echo "  $name"
  if publish_directory_record "$name" "$pub" "$sec"; then
    count=$((count + 1))
  fi
done

echo
echo "$count directory record(s) refreshed."
# No restart needed: this record is read by CLIENTS, not by the agent process. Desktop polls
# list_relay_agents every 5 minutes (hooks.ts: "this poll is also the ONLY refresh path"), so the UI
# catches up on its own — reopen the profile panel to see it immediately.
echo "Clients pick this up on their next poll (Desktop: within ~5 min, or reopen the profile panel)."
