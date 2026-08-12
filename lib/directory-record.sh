#!/usr/bin/env bash
# directory-record.sh — publish an agent's kind:10100 relay directory record.
#
# Sourced by attest-agent.sh and sync-directory.sh. Not executable on its own.
#
# WHAT THE RECORD IS FOR
# The kind:10100 record is a client-facing DIRECTORY entry: name, channels, respond_to. Clients read
# it to decide whether an agent is mentionable, which channel to open its Activity panel in, and what
# to list under its profile.
#
# WHY IT GOES STALE — and why that is invisible
# `channel_ids` is a DENORMALIZED SNAPSHOT of membership taken at publish time. Nothing republishes
# it: buzz-acp never touches kind:10100, the relay reads only `channel_add_policy` from it
# (buzz-relay/src/handlers/side_effects.rs: handle_agent_profile), and Desktop treats it as
# "near-static … this poll is also the ONLY refresh path" (desktop/src/features/agents/hooks.ts).
# So the moment an agent is added to a channel through ANY other path — the Desktop member picker,
# `buzz channels add-member`, cortex provisioning — the record is wrong, with nothing logged.
#
# The agent itself is fine: buzz-acp subscribes to membership notifications and joins the new channel
# live. It is only the client-facing record that lies, which makes this look like an agent bug
# ("the agent doesn't know it's in the channel") when it is a directory-staleness bug.
# Hit live 2026-08-11: qa-lead added to #jira management via the UI, subscribed correctly at the ACP
# layer, and still showed "Channels 1" in its profile.
#
# 10100 IS REPLACEABLE — so every publish must carry the FULL record. A partial write (notably
# `buzz channels set-add-policy`, which sends only channel_add_policy) clobbers
# name/channel_ids/respond_to and leaves the agent unmentionable and unobservable.
#
# NOTE: this record is signed by the AGENT's own key, not the owner's — so refreshing it needs no
# human secret and can run unattended, unlike attestation.

# publish_directory_record <name> <agent_pubkey> <agent_secret>
# Requires: BUZZ (buzz CLI path), SIGN (sign_event example path), RELAY_HTTP.
publish_directory_record() {
  local name="$1" pub="$2" sec="$3" ids=() names=() cid cname

  # Membership is NOT derivable from `channels list` — that returns every VISIBLE channel — so probe
  # each one. Getting this wrong is not cosmetic: 10100 is replaceable, so a short list silently
  # removes the agent from channels it is really in.
  while IFS=$'\t' read -r cid cname; do
    [ -n "$cid" ] || continue
    if BUZZ_RELAY_URL="$RELAY_HTTP" BUZZ_PRIVATE_KEY="$sec" \
         "$BUZZ" channels members --channel "$cid" 2>/dev/null | grep -q "$pub"; then
      ids+=("$cid"); names+=("$cname")
    fi
  done < <(BUZZ_RELAY_URL="$RELAY_HTTP" BUZZ_PRIVATE_KEY="$sec" "$BUZZ" channels list 2>/dev/null \
             | python3 -c 'import json,sys
for c in json.load(sys.stdin): print(c["channel_id"] + "\t" + c["name"])' 2>/dev/null)

  if [ "${#ids[@]}" -eq 0 ]; then
    echo "      ! in no channels — skipping directory record (it would be unmentionable anyway)" >&2
    return 1
  fi

  local content event
  # splitlines(), NEVER split(): a channel name may contain SPACES ("jira management"), and bare
  # split() would shatter it into two entries — desynchronizing channels[] from channel_ids[] so that
  # name i no longer describes id i. Desktop pairs them positionally
  # (useManagedAgentActions.ts: "a misaligned channels/channelIds pairing would otherwise…"), so the
  # damage is worse than a stale record: the Activity panel would open the WRONG channel. Caught by
  # testing this very function against a channel called "jira management" (2026-08-11).
  content="$(NAME="$name" IDS="$(printf '%s\n' "${ids[@]}")" NAMES="$(printf '%s\n' "${names[@]}")" \
    python3 -c 'import json,os
n = os.environ["NAME"]
names = os.environ["NAMES"].splitlines()
ids = os.environ["IDS"].splitlines()
assert len(names) == len(ids), f"channels/channel_ids length mismatch: {len(names)} vs {len(ids)}"
print(json.dumps({
    "name": n, "display_name": n, "agent_type": "agent",
    "about": f"Synapse agent ({n}).",
    "channels": names,
    "channel_ids": ids,
    "capabilities": [], "status": "online",
    "respond_to": "anyone", "channel_add_policy": "anyone",
}))')"
  event="$("$SIGN" "$sec" 10100 "$content")" || return 1
  curl -sS -X POST "$RELAY_HTTP/events" -H "X-Pubkey: $pub" \
       -H 'Content-Type: application/json' --data-binary "$event" >/dev/null || return 1
  echo "      channels: ${names[*]}"
}
