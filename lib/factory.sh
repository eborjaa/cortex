#!/usr/bin/env bash
# factory.sh — Cortex harness core: doctor / status / start / stop / launchd / test-mcp / provision.
# Invoked by bin/cortex.mjs. All personal values come from the instance's factory.config; this file
# ships in the package and holds none.
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$LIB/config.sh"
cortex_load

CMD="${1:-status}"; shift || true
LABEL_PREFIX="${CORTEX_LABEL_PREFIX:-com.cortex}"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
# Buzz dev-DB creds (docker-compose defaults; override if you changed them)
PG_PW="${BUZZ_PG_PASSWORD:-buzz_dev}"; PG_USER="${BUZZ_PG_USER:-buzz}"; PG_DB="${BUZZ_PG_DB:-buzz}"

ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; FAIL=1; }
warn() { echo "  warn $*"; }
FAIL=0

agent_env()  { echo "$HOME/.config/buzz/agents/$1.env"; }
buzz_cli()   { local c="$BUZZ_REPO/target/debug/buzz"; [ -x "$c" ] || c="$BUZZ_REPO/target/release/buzz"; echo "$c"; }
runtime()    { echo "$BUZZ_SYNAPSE_AGENT_COMMAND"; }

agent_running() {
  local a="$1"
  [ -f "$INSTANCE/logs/$a.pid" ] && kill -0 "$(cat "$INSTANCE/logs/$a.pid")" 2>/dev/null && return 0
  [ -f "$(agent_env "$a")" ] || return 1
  # shellcheck disable=SC1090
  . "$(agent_env "$a")"
  pgrep -f "buzz-acp.*${SEC:0:16}" >/dev/null 2>&1
}

channel_id() {
  [ -f "$BUZZ_OWNER_ENV" ] || return 1
  # shellcheck disable=SC1090
  ( . "$BUZZ_OWNER_ENV"
    BUZZ_RELAY_URL="${BUZZ_RELAY_HTTP:-http://localhost:3000}" BUZZ_PRIVATE_KEY="$SEC" \
      "$(buzz_cli)" channels list 2>/dev/null | CH="$BUZZ_DEFAULT_CHANNEL_NAME" python3 -c '
import json,os,sys
want=os.environ["CH"]
for c in json.load(sys.stdin):
  if c.get("name")==want: print(c["channel_id"]); sys.exit(0)
sys.exit(1)' )
}

is_channel_member() {
  PGPASSWORD="$PG_PW" psql -h localhost -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT 1 FROM channel_members WHERE removed_at IS NULL AND channel_id='$1' AND encode(pubkey,'hex')='$2' LIMIT 1" \
    2>/dev/null | grep -q 1
}

doctor() {
  echo "== doctor =="
  local rt; rt="$(runtime)"
  echo "-- binaries --"
  [ -x "$BUZZ_REPO/target/debug/buzz-relay" ] || [ -x "$BUZZ_REPO/target/release/buzz-relay" ] \
    && ok "buzz-relay" || bad "buzz-relay missing — build Buzz in $BUZZ_REPO"
  [ -x "$BUZZ_REPO/target/debug/buzz-acp" ] || [ -x "$BUZZ_REPO/target/release/buzz-acp" ] \
    && ok "buzz-acp" || bad "buzz-acp missing"
  [ -x "$(buzz_cli)" ] && ok "buzz CLI" || bad "buzz CLI missing"
  command -v "$rt" >/dev/null && ok "$rt on PATH (agent runtime)" || bad "$rt missing — agent runtime"
  case "$rt" in
    claude-agent-acp) claude-agent-acp --version </dev/null >/dev/null 2>&1 && ok "claude-agent-acp runnable" || bad "claude-agent-acp not runnable" ;;
    cursor-agent)     cursor-agent acp --help >/dev/null 2>&1 && ok "cursor-agent acp" || bad "cursor-agent acp unavailable" ;;
    *)                warn "unrecognized runtime $rt — skipping probe" ;;
  esac
  [ -x "$(synapse_bin)" ] && ok "synapse engine (vault)" || bad "synapse not installed in vault — npm i in $SYNAPSE_VAULT"
  [ -x "$(synapse_mcp_bin)" ] && ok "synapse-mcp (vault)" || bad "synapse-mcp missing — needs @eborja/synapse >=0.2 in the vault"

  echo "-- infra --"
  nc -z 127.0.0.1 3000 >/dev/null 2>&1 && ok "relay :3000" || bad "relay down — cortex start-relay (or launchd)"
  redis-cli ping >/dev/null 2>&1 && ok "redis ping" || warn "redis not answering (relay may still be starting)"
  PGPASSWORD="$PG_PW" psql -h localhost -U "$PG_USER" -d "$PG_DB" -c 'SELECT 1' >/dev/null 2>&1 \
    && ok "postgres query" || warn "postgres not answering"

  echo "-- auth / runtime --"
  case "$rt" in
    claude-agent-acp) claude auth status 2>/dev/null | grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true' && ok "claude logged in" || bad "claude not logged in — claude auth login" ;;
    cursor-agent)     cursor-agent status 2>/dev/null | grep -qi 'Logged in' && ok "cursor-agent logged in" || bad "cursor-agent not logged in — cursor-agent login" ;;
  esac
  env | grep -q '^BUZZ_ACP_BASE_PROMPT_FILE=' && bad "BUZZ_ACP_BASE_PROMPT_FILE set — role prompts must use SYSTEM only" || ok "BASE prompt unset"
  ok "prompt source: $PROMPT_SOURCE"

  echo "-- addressable agents (roster derived from the vault) --"
  local cid; cid="$(channel_id 2>/dev/null || true)"
  if [ -n "$cid" ]; then ok "#$BUZZ_DEFAULT_CHANNEL_NAME id $cid"
  elif ! nc -z 127.0.0.1 3000 >/dev/null 2>&1; then bad "#$BUZZ_DEFAULT_CHANNEL_NAME unknown — relay down"
  else bad "#$BUZZ_DEFAULT_CHANNEL_NAME missing — create it in Buzz Desktop"; fi

  for a in "${STANDING[@]}"; do
    echo "  [$a]  hub=$(agent_hub "$a") surface=$(agent_surface "$a") model=$(agent_model "$a")"
    if [ "$PROMPT_SOURCE" = "render" ]; then
      SYNAPSE_VAULT="$SYNAPSE_VAULT" "$(synapse_bin)" render "agent-$a" "$(agent_hub "$a")" --profile "$(agent_profile "$a")" >/dev/null 2>&1 \
        && ok "    prompt renders" || bad "    render fails for agent-$a / $(agent_hub "$a")"
    else
      [ -f "$INSTANCE/prompts/$a.system.md" ] && ok "    prompt file" || bad "    missing prompts/$a.system.md"
    fi
    [ -f "$(agent_env "$a")" ] && ok "    env keys" || bad "    missing keys — cortex provision $a"
    if [ -f "$(agent_env "$a")" ] && [ -n "$cid" ]; then
      # shellcheck disable=SC1090
      . "$(agent_env "$a")"
      is_channel_member "$cid" "$PUB" && ok "    member of #$BUZZ_DEFAULT_CHANNEL_NAME" || bad "    NOT in #$BUZZ_DEFAULT_CHANNEL_NAME — cortex provision $a"
    fi
    agent_running "$a" && ok "    process running" || warn "    process down (start when ready)"
  done

  [ "$FAIL" -eq 0 ] && { echo; echo "Doctor clean."; } || { echo; echo "Doctor FAILED ($FAIL) — fix each FAIL, then re-run cortex doctor"; }
  return $FAIL
}

status() {
  echo "== status =="
  nc -z 127.0.0.1 3000 >/dev/null 2>&1 && ok "relay :3000" || echo "  down  relay"
  for a in "${STANDING[@]}"; do agent_running "$a" && ok "$a up" || echo "  down  $a"; done
}

launchctl_ensure() {
  local label="$1" uid; uid="$(id -u)"
  local plist="$LAUNCH_DIR/${LABEL_PREFIX}-$label.plist" id="gui/$uid/${LABEL_PREFIX}-$label"
  [ -f "$plist" ] || return 1
  if launchctl print "$id" >/dev/null 2>&1; then launchctl kickstart -k "$id" 2>/dev/null || true; return 0; fi
  launchctl bootout "$id" 2>/dev/null || true; sleep 1
  launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null && return 0
  sleep 2; launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || launchctl load "$plist" 2>/dev/null || true
  launchctl print "$id" >/dev/null 2>&1
}

# Wait until TCP :$1 has NO listener, up to $2 s. The relay graceful-drains for up to 30s on SIGTERM
# while still holding the port, so a new relay started too soon cannot bind and launchd drops it.
# Teardown calls this so "stopped" means the port is actually free, not just signalled.
wait_port_free() {
  local port="${1:-3000}" max="${2:-40}" i=0
  while nc -z 127.0.0.1 "$port" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge "$max" ] && { echo "  ! port $port still busy after ${max}s (relay may be hung)" >&2; return 1; }
    sleep 1
  done
}

# Wait until TCP :$1 HAS a listener, up to $2 s — an accurate "is it up yet?" instead of a fixed sleep.
wait_port_up() {
  local port="${1:-3000}" max="${2:-12}" i=0
  until nc -z 127.0.0.1 "$port" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge "$max" ] && return 1
    sleep 1
  done
}

start_relay() {
  mkdir -p "$INSTANCE/logs"
  nc -z 127.0.0.1 3000 >/dev/null 2>&1 && { ok "relay already up"; return 0; }
  if [ -f "$LAUNCH_DIR/${LABEL_PREFIX}-relay.plist" ]; then launchctl_ensure relay
    wait_port_up 3000 12 && { ok "relay started (launchd)"; return 0; }; fi
  CORTEX_INSTANCE="$INSTANCE" nohup bash "$LIB/run-relay.sh" >>"$INSTANCE/logs/relay.log" 2>&1 &
  echo $! >"$INSTANCE/logs/relay.pid"; disown $! 2>/dev/null || true
  wait_port_up 3000 12 && ok "relay started (nohup)" || { bad "relay failed"; tail -20 "$INSTANCE/logs/relay.log"; return 1; }
}

start_agent() {
  local a="$1"; mkdir -p "$INSTANCE/logs"
  CORTEX_INSTANCE="$INSTANCE" bash "$LIB/provision-agent.sh" "$a"
  agent_running "$a" && { ok "$a already running"; return 0; }
  if [ -f "$LAUNCH_DIR/${LABEL_PREFIX}-$a.plist" ]; then launchctl_ensure "$a" || true; sleep 2
    agent_running "$a" && { ok "started $a (launchd)"; return 0; }; fi
  CORTEX_INSTANCE="$INSTANCE" nohup bash "$LIB/run-agent.sh" "$a" >/dev/null 2>&1 &
  echo $! >"$INSTANCE/logs/$a.pid"; disown $! 2>/dev/null || true; sleep 2
  agent_running "$a" && ok "started $a (nohup)" || { bad "start $a failed"; tail -30 "$INSTANCE/logs/$a.log" || true; return 1; }
}

stop_agent() {
  local a="$1"
  [ -f "$LAUNCH_DIR/${LABEL_PREFIX}-$a.plist" ] && { launchctl bootout "gui/$(id -u)/${LABEL_PREFIX}-$a" 2>/dev/null || launchctl unload "$LAUNCH_DIR/${LABEL_PREFIX}-$a.plist" 2>/dev/null || true; }
  if [ -f "$(agent_env "$a")" ]; then # shellcheck disable=SC1090
    . "$(agent_env "$a")"; pkill -f "buzz-acp.*${SEC:0:24}" 2>/dev/null || true; fi
  [ -f "$INSTANCE/logs/$a.pid" ] && { kill "$(cat "$INSTANCE/logs/$a.pid")" 2>/dev/null || true; rm -f "$INSTANCE/logs/$a.pid"; }
  # A busy turn ignores SIGTERM; wait, then SIGKILL — so `restart` never sees it as "already running".
  if [ -n "${SEC:-}" ]; then
    for _ in 1 2 3 4 5; do pgrep -f "buzz-acp.*${SEC:0:24}" >/dev/null 2>&1 || break; sleep 1; done
    pgrep -f "buzz-acp.*${SEC:0:24}" >/dev/null 2>&1 && pkill -9 -f "buzz-acp.*${SEC:0:24}" 2>/dev/null || true
  fi
  echo "  stopped $a"
}

stop_relay() {
  [ -f "$LAUNCH_DIR/${LABEL_PREFIX}-relay.plist" ] && { launchctl bootout "gui/$(id -u)/${LABEL_PREFIX}-relay" 2>/dev/null || launchctl unload "$LAUNCH_DIR/${LABEL_PREFIX}-relay.plist" 2>/dev/null || true; }
  [ -f "$INSTANCE/logs/relay.pid" ] && { kill "$(cat "$INSTANCE/logs/relay.pid")" 2>/dev/null || true; rm -f "$INSTANCE/logs/relay.pid"; }
  pkill -f 'buzz-relay' 2>/dev/null || true
  wait_port_free 3000 || true          # block until the drain releases :3000, so a start after us can bind
  echo "  stopped relay"
}

# Emit a LaunchAgent plist for the relay or an agent. All paths absolute; CORTEX_INSTANCE passed in.
write_plist() {
  local kind="$1" plist prog
  mkdir -p "$INSTANCE/launchd" "$LAUNCH_DIR"
  local common_env="    <key>CORTEX_INSTANCE</key><string>${INSTANCE}</string>
    <key>SYNAPSE_VAULT</key><string>${SYNAPSE_VAULT}</string>
    <key>PATH</key><string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>"
  if [ "$kind" = "relay" ]; then
    plist="$INSTANCE/launchd/${LABEL_PREFIX}-relay.plist"
    cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL_PREFIX}-relay</string>
  <key>WorkingDirectory</key><string>${BUZZ_REPO}</string>
  <key>EnvironmentVariables</key><dict>
${common_env}
  </dict>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>${LIB}/run-relay.sh</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${INSTANCE}/logs/relay.launchd.log</string>
  <key>StandardErrorPath</key><string>${INSTANCE}/logs/relay.launchd.log</string>
</dict></plist>
PLIST
  else
    local a="$kind"
    plist="$INSTANCE/launchd/${LABEL_PREFIX}-$a.plist"
    cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL_PREFIX}-$a</string>
  <key>WorkingDirectory</key><string>${INSTANCE}</string>
  <key>EnvironmentVariables</key><dict>
${common_env}
  </dict>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>${LIB}/run-agent.sh</string><string>$a</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${INSTANCE}/logs/$a.launchd.log</string>
  <key>StandardErrorPath</key><string>${INSTANCE}/logs/$a.launchd.log</string>
</dict></plist>
PLIST
  fi
  cp "$plist" "$LAUNCH_DIR/"
  ok "wrote ${LABEL_PREFIX}-${kind}"
}

install_launchagents() {
  echo "== install LaunchAgents =="
  write_plist relay
  for a in "${STANDING[@]}"; do write_plist "$a"; done
  echo "Load with: cortex launchd-load"
}

launchd_load() {
  mkdir -p "$INSTANCE/logs"
  wait_port_free 3000 || true          # a prior relay may still be draining — don't race its port
  launchctl_ensure relay && ok "loaded ${LABEL_PREFIX}-relay" || bad "load relay"
  wait_port_up 3000 12 && ok "relay :3000 ready" || warn "relay not answering yet"
  for a in "${STANDING[@]}"; do launchctl_ensure "$a" && ok "loaded ${LABEL_PREFIX}-$a" || bad "load $a"; sleep 1; done
  return $FAIL
}

launchd_unload() {
  for a in "${STANDING[@]}"; do launchctl bootout "gui/$(id -u)/${LABEL_PREFIX}-$a" 2>/dev/null || true; echo "  unloaded $a"; done
  launchctl bootout "gui/$(id -u)/${LABEL_PREFIX}-relay" 2>/dev/null || true; echo "  unloaded relay"
  wait_port_free 3000 || true          # finish the graceful drain before returning, so load is safe
}

test_mcp() {
  echo "== test-mcp =="
  local report
  report=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"cortex-test","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | SYNAPSE_VAULT="$SYNAPSE_VAULT" SYNAPSE_MCP_SURFACE="$SYNAPSE_MCP_SURFACE" "$(synapse_mcp_bin)" 2>/dev/null \
    | python3 -c 'import sys,json
n=[]
for l in sys.stdin:
  try: m=json.loads(l)
  except Exception: continue
  if m.get("id")==2 and "result" in m: n=sorted(t["name"] for t in m["result"]["tools"])
print(len(n)); print(" ".join(n))') || true
  local count; count=$(echo "$report" | sed -n 1p)
  [ "${count:-0}" -ge 10 ] && ok "mcp tools/list ($count tools)" || bad "mcp tools/list returned ${count:-0}"
  echo "$report" | sed -n 2p | tr ' ' '\n' | grep -q synapse_lint && ok "  synapse_lint present" || bad "  synapse_lint missing"
  return $FAIL
}

# agents-sync — materialize every vault agent as a Claude Code subagent type in ~/.claude/agents/,
# so an orchestrator can Task-spawn any of them BY NAME with the full synapse toolset. The vault is
# the registry (each agent note = purpose + role); this only DEPLOYS it — no agent list is hardcoded,
# so adding an agent to the vault and re-running this is all it takes. Idempotent.
agents_sync() {
  local dest="$HOME/.claude/agents"; mkdir -p "$dest"
  local sb; sb="$(synapse_bin)"
  [ -x "$sb" ] || { bad "synapse CLI not found at $sb"; return 1; }
  local n=0
  for f in "$SYNAPSE_VAULT"/agents/agent-*.md; do
    [ -e "$f" ] || { warn "no agents under $SYNAPSE_VAULT/agents"; break; }
    local id name purpose body
    id="$(basename "$f" .md)"; name="${id#agent-}"
    purpose="$(sed -n 's/^purpose:[[:space:]]*//p' "$f" | head -1)"
    purpose="${purpose%\"}"; purpose="${purpose#\"}"          # strip surrounding quotes
    [ -n "$purpose" ] || purpose="Synapse $name agent."
    purpose="${purpose//\"/\\\"}"                             # escape internal quotes for YAML
    if ! body="$(SYNAPSE_VAULT="$SYNAPSE_VAULT" "$sb" render "$id" 2>/dev/null)" || [ -z "$body" ]; then
      warn "render failed for $id — skipped"; continue
    fi
    {
      printf -- '---\nname: %s\ndescription: "%s"\n---\n' "$name" "$purpose"
      printf -- '<!-- GENERATED by `cortex agents-sync` from %s — edit the vault note, not this file. -->\n\n' "$id"
      printf -- '%s\n' "$body"
    } >"$dest/$name.md"
    n=$((n + 1)); ok "synced $name"
  done
  echo "  $n agent(s) → $dest"
}

case "$CMD" in
  doctor) doctor ;;
  status) status ;;
  start) case "${1:-all}" in all) agents_sync; start_relay; for a in "${STANDING[@]}"; do start_agent "$a"; done ;; relay) start_relay ;; *) start_agent "$1" ;; esac ;;
  start-relay) start_relay ;;
  stop) case "${1:-all}" in all) for a in "${STANDING[@]}"; do stop_agent "$a"; done; stop_relay ;; relay) stop_relay ;; *) stop_agent "$1" ;; esac ;;
  restart) "$LIB/factory.sh" stop "${1:-all}"; "$LIB/factory.sh" start "${1:-all}" ;;
  provision) CORTEX_INSTANCE="$INSTANCE" bash "$LIB/provision-agent.sh" "${1:?usage: cortex provision <name>}" ;;
  install-launchagents) install_launchagents ;;
  launchd-load) launchd_load; exit $FAIL ;;
  launchd-unload) launchd_unload ;;
  test-mcp) test_mcp; exit $FAIL ;;
  agents-sync) agents_sync ;;
  *) echo "unknown factory command: $CMD" >&2; exit 2 ;;
esac
