#!/usr/bin/env bash
# run-agent.sh — launch ONE Synapse standing agent on Buzz. Invoked by `cortex start` and directly
# by LaunchAgents (which pass CORTEX_INSTANCE in the plist).
#
#   CORTEX_INSTANCE=/path/to/instance bash <cortex>/lib/run-agent.sh <name>
#
# Behaviour, all driven by the instance's factory.config:
#   - system prompt is RENDERED from the vault (`synapse render <agent> <hub> --profile <p>`) so the
#     agent's behaviour is defined in Synapse, not hand-written here (fallback: prompts/<name>.system.md)
#   - MCP is injected per-agent with that agent's own surface, so e.g. oracle on `standard` never sees
#     the create_* tools — read-only by construction, not by prompt
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$LIB/config.sh"
cortex_load

NAME="${1:?usage: run-agent.sh <name>}"; NAME="${NAME#agent-}"

KEYDIR="$HOME/.config/buzz/agents"
[ -f "$KEYDIR/$NAME.env" ] || { echo "run-agent: no keys for $NAME — run: cortex provision $NAME" >&2; exit 1; }
# shellcheck disable=SC1090
. "$KEYDIR/$NAME.env"                                   # PUB, SEC, AGENT
# shellcheck disable=SC1090
[ -f "$HOME/.config/buzz/relay.env" ] && . "$HOME/.config/buzz/relay.env"
export PATH="$HOME/.local/bin:$PATH"

ACP="$BUZZ_REPO/target/debug/buzz-acp"; [ -x "$ACP" ] || ACP="$BUZZ_REPO/target/release/buzz-acp"
[ -x "$ACP" ] || { echo "run-agent: buzz-acp not built in $BUZZ_REPO" >&2; exit 1; }

SURFACE="$(agent_surface "$NAME")"
HUB="$(agent_hub "$NAME")"
PROFILE="$(agent_profile "$NAME")"
RUNTIME="$(agent_runtime_for "$NAME")"
MODEL_ID="$(agent_model "$NAME")"
WORKERS="$(agent_workers "$NAME")"
IDLE_TIMEOUT="$(agent_idle_timeout "$NAME")"
MAX_TURN="$(agent_max_turn "$NAME")"

mkdir -p "$INSTANCE/logs" "$INSTANCE/.cortex" "$INSTANCE/prompts"
echo "starting $NAME $(date -u +%Y-%m-%dT%H:%M:%SZ) · runtime=$RUNTIME surface=$SURFACE hub=$HUB" >>"$INSTANCE/logs/$NAME.log"

# ── system prompt: render from the vault, else hand-written fallback ──────────────
SYS="$INSTANCE/.cortex/${NAME}.system.md"
SB="$(synapse_bin)"
if [ "$PROMPT_SOURCE" = "render" ] && [ -x "$SB" ]; then
  if SYNAPSE_VAULT="$SYNAPSE_VAULT" "$SB" render "agent-$NAME" "$HUB" --profile "$PROFILE" \
       >"$SYS.tmp" 2>>"$INSTANCE/logs/$NAME.log" && [ -s "$SYS.tmp" ]; then
    mv "$SYS.tmp" "$SYS"
  else
    rm -f "$SYS.tmp"
    echo "  render failed for $NAME — falling back to a hand-written prompt" >>"$INSTANCE/logs/$NAME.log"
  fi
fi
[ -s "$SYS" ] || SYS="$INSTANCE/prompts/${NAME}.system.md"
[ -f "$SYS" ] || { echo "run-agent: no prompt for $NAME (render failed, no prompts/$NAME.system.md)" >&2; exit 1; }
export BUZZ_ACP_SYSTEM_PROMPT_FILE="$SYS"

# ── per-agent MCP wrapper: pins the vault + THIS agent's surface + plugin discovery ──
MCP="$INSTANCE/.cortex/mcp-${NAME}.sh"
MCP_ENV="$(agent_mcp_env "$NAME")"
{
  echo '#!/usr/bin/env bash'
  echo "export SYNAPSE_VAULT=\"$SYNAPSE_VAULT\""
  echo "export SYNAPSE_MCP_SURFACE=\"$SURFACE\""
  # Which instance this agent belongs to — the operator MCP plugin (templates/mcp-plugins/cortex.mjs)
  # needs it to answer "is this agent actually running / attested / authed". Harmless when unused.
  echo "export CORTEX_INSTANCE=\"$INSTANCE\""
  [ -n "${SYNAPSE_MCP_PLUGINS:-}" ] && echo "export SYNAPSE_MCP_PLUGINS=\"$SYNAPSE_MCP_PLUGINS\""
  # Vault secrets (Zephyr token, …) so a vault MCP plugin can reach its upstream API. The wrapper is
  # exec'd by the ACP runtime, which does NOT forward our environment, so re-source rather than assume.
  [ -f "$SYNAPSE_VAULT/.env" ] && echo "set -a; . \"$SYNAPSE_VAULT/.env\"; set +a"
  [ -f "$INSTANCE/.env" ]      && echo "set -a; . \"$INSTANCE/.env\"; set +a"
  # Per-agent plugin config (AGENT_<name>_MCP_ENV="K=V;K2=V2") — narrows a plugin for THIS agent only.
  if [ -n "$MCP_ENV" ]; then
    printf '%s\n' "$MCP_ENV" | tr ';' '\n' | while IFS= read -r kv; do
      [ -n "$kv" ] && echo "export ${kv}"
    done
  fi
  echo "exec \"$(synapse_mcp_bin)\" \"\$@\""
} >"$MCP"
chmod +x "$MCP"

# ── per-agent working dir (NO tool deny-list) ──────────────────────────────────────
# A standing agent REPLIES on Buzz by shelling out to `buzz messages send` (the compiled-in base
# prompt teaches this CLI; there is no channel-reply tool — `SendMessage` is agent-to-agent only).
# That reply path needs the shell tool (`Bash`). An earlier build denied `Bash` (and file/web tools)
# as a "tool sandbox" to stop a reconcile wandering the filesystem — but denying `Bash` SEVERED every
# reply: the agent computed an answer, hunted for a reply tool that does not exist, and ended the turn
# without posting. Verified live 2026-08-03 (curator: "I need Bash to run buzz messages send").
#
# So we do NOT sandbox tools here. The agent runs like oracle — no deny-list — bounded by the turn
# caps below (--idle-timeout/--max-turn-duration) and its own throwaway working dir. Drift is a
# role/prompt-layer concern, not a tool-removal one. If a future build reintroduces a lockdown, it
# MUST keep the reply path working (e.g. a first-class Buzz reply tool) — never deny the shell.
AGDIR="$INSTANCE/.cortex/agents/$NAME"
mkdir -p "$AGDIR"
# Clear only a settings.json that carries a DENY-LIST (what the 0.2.1 build wrote — it severed replies).
# A settings.json without one is intentional operator config and must survive: claude-agent-acp reads
# the user's ~/.claude/settings.json, and its resolvePermissionMode() accepts only
# default|acceptEdits|dontAsk|plan|bypassPermissions. A user whose GLOBAL Claude Code config selects a
# newer mode (e.g. "auto") makes every agent here die at session/new with
#   -32603 Internal error · "Invalid permissions.defaultMode: auto."
# buzz-acp then requeues with backoff, so the symptom is an agent that is "up", receives the mention,
# and silently never replies (verified live 2026-08-06, all 12 REL agents). A project-scoped
# settings.json pins a mode the adapter understands without touching the user's global config —
# blowing it away every launch would resurrect the bug on every restart.
if [ -f "$AGDIR/.claude/settings.json" ] && grep -q '"deny"' "$AGDIR/.claude/settings.json" 2>/dev/null; then
  rm -f "$AGDIR/.claude/settings.json"
fi
cd "$AGDIR"

# cursor-agent and opencode both need the `acp` subcommand; claude-agent-acp takes none.
AARGS=""
case "$RUNTIME" in
  cursor-agent|opencode) AARGS="acp" ;;
esac

# Optional args, built as an array so an unset one contributes nothing (an empty string would be
# parsed as a positional). MODEL_ID=default means "let the runtime choose" — pass no --model at all.
OPT=()
[ -n "$MODEL_ID" ] && [ "$MODEL_ID" != "default" ] && OPT+=(--model "$MODEL_ID")
# Only pass --agents when it differs from buzz-acp's own default, so the common case keeps the
# adapter's default rather than this file restating it.
[ "$WORKERS" != "1" ] && OPT+=(--agents "$WORKERS")
[ -n "${AGENT_OWNER:-}" ] && OPT+=(--agent-owner "$AGENT_OWNER")
# The owner's NIP-OA attestation (minted at provision time, stored in this agent's env file) is read
# by buzz-acp from the ENVIRONMENT — it has no CLI flag — and exported below, not appended here.
if [ "${RELAY_OBSERVER:-1}" = "1" ]; then
  OPT+=(--relay-observer)
  [ -n "${AGENT_OWNER:-}" ] || echo "run-agent: RELAY_OBSERVER=1 but AGENT_OWNER is unset — observer frames will NOT be published (set AGENT_OWNER or BUZZ_OWNER_ENV in factory.config)" >&2
fi

# BUZZ_AUTH_TAG is buzz-acp's PRIORITY-1 owner source — it overrides --agent-owner. So an attestation
# signed by a different identity than AGENT_OWNER silently redirects observer frames to that signer,
# and the client you watch from can no longer decrypt them. Warn rather than let the panel go dark.
if [ -n "${BUZZ_AUTH_TAG:-}" ] && [ -n "${AGENT_OWNER:-}" ]; then
  TAG_OWNER="$(printf '%s' "$BUZZ_AUTH_TAG" | sed -n 's/^\["auth","\([0-9a-f]\{64\}\)".*/\1/p')"
  [ -n "$TAG_OWNER" ] && [ "$TAG_OWNER" != "$AGENT_OWNER" ] && \
    echo "run-agent: BUZZ_AUTH_TAG attests owner ${TAG_OWNER:0:16}… but AGENT_OWNER is ${AGENT_OWNER:0:16}… — the attestation WINS, so observer frames go to the attested owner. Re-mint the attestation with the identity you watch from." >&2
fi

# An agent REPLIES by shelling out to `buzz messages send` — but buzz-acp receives its identity as a
# CLI flag, so the shell that runs the agent's tools inherits NOTHING. Every reply therefore began by
# hunting for and sourcing the per-agent env file, and a turn that spent its budget on the actual work
# ended without ever publishing — a silent failed turn ("unposted = failed", rule-buzz-reply-contract).
# Observed live 2026-08-04: oracle ran a full 2-minute investigation and posted nothing.
# Exporting both here makes `buzz messages send` work with zero setup. No new exposure: the agent
# already reads this key from its own env file, and this is its own identity, not the owner's.
#
# --permission-mode is overridable and defaults to a value EVERY buzz-acp build accepts.
# `bypass-permissions` was hardcoded here by the #8 revert, but older builds reject it outright —
#   error: invalid value 'bypass-permissions' for '--permission-mode'
#   [possible values: default, accept-edits, dont-ask, plan]
# — and buzz-acp exits before connecting, so the agent never starts and says nothing in chat. Killed
# qa-lead on restart 2026-08-11. Set BUZZ_ACP_PERMISSION_MODE=bypass-permissions on a build that
# supports it; the default stays compatible.
#
# Two URLs, two schemes, one source of truth. The agent's TOOLS shell out to `buzz messages send`,
# which wants HTTP; buzz-acp's own relay socket is a WEBSOCKET and rejects an http:// URL outright:
#   WARN buzz_acp::relay: initial relay connect failed with terminal error:
#   WebSocket error: URL error: URL scheme not supported
# So --relay-url coerces the scheme to ws:// while BUZZ_RELAY_URL stays http:// for the tools. The #8
# revert dropped that coercion and passed http:// straight through, which starts the agent pool
# successfully and THEN dies on connect — the agent looks like it booted and is simply absent. Killed
# qa-lead on restart 2026-08-11, same revert as the permission-mode breakage above.
#
# NOTE: never put a `#` comment inside the backslash-continued arg list below — line continuation
# joins the lines first, so the comment text becomes literal ARGUMENTS. That produced a start that
# logged nothing at all (also 2026-08-11). Comments belong here, above `exec`.
exec env \
  RUST_LOG=info \
  PATH="$HOME/.local/bin:$PATH" \
  BUZZ_PRIVATE_KEY="$SEC" \
  BUZZ_RELAY_URL="ws://${BUZZ_RELAY_URL#*://}" \
  ${BUZZ_AUTH_TAG:+BUZZ_AUTH_TAG="$BUZZ_AUTH_TAG"} \
  "$ACP" \
  --private-key "$SEC" \
  --relay-url "ws://${BUZZ_RELAY_URL#*://}" \
  --agent-command "$RUNTIME" \
  --agent-args "$AARGS" \
  --mcp-command "$MCP" \
  --permission-mode "${BUZZ_ACP_PERMISSION_MODE:-accept-edits}" \
  --respond-to anyone \
  --idle-timeout "$IDLE_TIMEOUT" \
  --max-turn-duration "$MAX_TURN" \
  ${OPT[@]+"${OPT[@]}"} \
  >>"$INSTANCE/logs/$NAME.log" 2>&1
