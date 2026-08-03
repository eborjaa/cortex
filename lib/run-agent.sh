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

# ── per-agent tool sandbox ────────────────────────────────────────────────────────
# A working dir whose .claude/settings.json denies ONLY the filesystem-drift vectors — shell, file
# edits, and web — the tools that turned a reconcile into a 6-minute wander into the wrong repo.
# claude-agent-acp reads project permissions from cwd, and `deny` wins even under bypass-permissions
# (removes the tool outright), so a standing agent works THROUGH the vault MCP and delegates.
#
# Cost is bounded SEPARATELY by the turn caps below (--idle-timeout/--max-turn-duration), which is
# reply-safe. Do NOT put that job on the deny-list: the Buzz reply/thread/handover path routes
# through SendMessage, which is a DEFERRED tool the agent must load via ToolSearch first — so denying
# ToolSearch (or SendMessage) silently kills the reply. Messaging + Task + ToolSearch stay ALLOWED so
# the agent can reply, start a thread, and mention the next agent for a handover.
AGDIR="$INSTANCE/.cortex/agents/$NAME"
mkdir -p "$AGDIR/.claude"
DENY='"Bash","Edit","Write","NotebookEdit","WebFetch","WebSearch"'
# Only a write-capable agent (full MCP surface) keeps the synchronous Task tool to delegate to doers;
# a read-only agent (standard/skeleton surface, e.g. oracle) does not spawn subagents.
[ "$SURFACE" = "full" ] || DENY="$DENY,\"Task\""
printf '{\n  "permissions": {\n    "deny": [%s]\n  }\n}\n' "$DENY" >"$AGDIR/.claude/settings.json"
cd "$AGDIR"

# cursor-agent needs the `acp` subcommand; claude-agent-acp takes none.
AARGS=""; [ "$RUNTIME" = "cursor-agent" ] && AARGS="acp"

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
  >>"$INSTANCE/logs/$NAME.log" 2>&1
