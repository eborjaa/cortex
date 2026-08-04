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
{
  echo '#!/usr/bin/env bash'
  echo "export SYNAPSE_VAULT=\"$SYNAPSE_VAULT\""
  echo "export SYNAPSE_MCP_SURFACE=\"$SURFACE\""
  [ -n "${SYNAPSE_MCP_PLUGINS:-}" ] && echo "export SYNAPSE_MCP_PLUGINS=\"$SYNAPSE_MCP_PLUGINS\""
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
rm -f "$AGDIR/.claude/settings.json"   # clear any deny-list a prior 0.2.1 build wrote (would block replies)
cd "$AGDIR"

# cursor-agent needs the `acp` subcommand; claude-agent-acp takes none.
AARGS=""; [ "$RUNTIME" = "cursor-agent" ] && AARGS="acp"

# Optional args, built as an array so an unset one contributes nothing (an empty string would be
# parsed as a positional). MODEL_ID=default means "let the runtime choose" — pass no --model at all.
OPT=()
[ -n "$MODEL_ID" ] && [ "$MODEL_ID" != "default" ] && OPT+=(--model "$MODEL_ID")
[ "${RELAY_OBSERVER:-1}" = "1" ] && OPT+=(--relay-observer)

exec env \
  RUST_LOG=info \
  PATH="$HOME/.local/bin:$PATH" \
  "$ACP" \
  --private-key "$SEC" \
  --relay-url "${BUZZ_RELAY_URL:-ws://localhost:3000}" \
  --agent-command "$RUNTIME" \
  --agent-args "$AARGS" \
  --mcp-command "$MCP" \
  --permission-mode bypass-permissions \
  --respond-to anyone \
  --idle-timeout "${BUZZ_ACP_IDLE_TIMEOUT:-300}" \
  --max-turn-duration "${BUZZ_ACP_MAX_TURN_DURATION:-600}" \
  ${OPT[@]+"${OPT[@]}"} \
  >>"$INSTANCE/logs/$NAME.log" 2>&1
