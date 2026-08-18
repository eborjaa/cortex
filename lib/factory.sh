#!/usr/bin/env bash
# factory.sh — Cortex harness core: doctor / status / start / stop / services / test-mcp / provision.
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
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
# Buzz dev-DB creds (docker-compose defaults; override if you changed them)
PG_PW="${BUZZ_PG_PASSWORD:-buzz_dev}"; PG_USER="${BUZZ_PG_USER:-buzz}"; PG_DB="${BUZZ_PG_DB:-buzz}"

ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; FAIL=1; }
warn() { echo "  warn $*"; }
FAIL=0

# agent_env() and buzz_cli() now live in config.sh — every command that touches an agent keyfile or
# the Buzz CLI needs them, not just this file.
runtime()    { echo "$BUZZ_SYNAPSE_AGENT_COMMAND"; }

systemd_unit_name() { echo "${LABEL_PREFIX}-$1.service"; }
systemd_unit_path() { echo "$SYSTEMD_DIR/$(systemd_unit_name "$1")"; }
systemd_unit_installed() {
  [ "$(uname -s)" = "Linux" ] && command -v systemctl >/dev/null 2>&1 \
    && [ -f "$(systemd_unit_path "$1")" ]
}

# Quote one systemd value without introducing a dependency on a platform-specific shell utility.
systemd_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; }
systemd_path() {
  local path="$1"
  path="${path//\\/\\\\}"
  path="${path// /\\x20}"
  path="${path//\"/\\x22}"
  path="${path//%/%%}"
  printf '%s' "$path"
}

require_systemd() {
  [ "$(uname -s)" = "Linux" ] || { echo "cortex: systemd commands are supported on Linux only" >&2; return 1; }
  command -v systemctl >/dev/null 2>&1 || { echo "cortex: systemctl is required for systemd commands" >&2; return 1; }
}

# Is this agent MID-TURN right now?
#
# Distinct from agent_running(): a process can be up while a turn is in flight, and restarting then
# KILLS that turn's work with no way to resume it. `restart --idle` uses this to skip busy agents.
#
# Detected from the log rather than a status API: buzz-acp logs `turn complete` at the end of every
# turn, so activity recorded AFTER the last `turn complete` means a turn is still running.
agent_busy() {
  # Two statements, not one: `local a="$1" log="…$a…"` declares BOTH names before assigning, so under
  # `set -u` the reference to $a in log's value is an unbound-variable error.
  local a="$1"
  local log="$INSTANCE/logs/$a.log" last_complete last_activity
  [ -f "$log" ] || return 1
  # Match on PLAIN text only. buzz-acp writes ANSI colour codes, so a pattern containing the target
  # prefix ("acp::tool: tool_call") never matches — the escapes sit between the module name and the
  # colon. Caught by testing the detector against a genuinely busy agent, where it reported "idle".
  last_complete="$(grep -n "turn complete" "$log" 2>/dev/null | tail -1 | cut -d: -f1)"
  last_activity="$(grep -nE "tool_call|acp::stream" "$log" 2>/dev/null | tail -1 | cut -d: -f1)"
  [ -n "$last_activity" ] || return 1
  [ -z "$last_complete" ] && return 0
  [ "$last_activity" -gt "$last_complete" ]
}

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

# Is pubkey $2 a member of channel $1?
#
# Asks the RELAY via the buzz CLI rather than querying Postgres directly. The psql version reported a
# false NEGATIVE on any machine without a postgres client installed: `psql` not found → empty output →
# `grep -q 1` fails → doctor printed "NOT in #<channel> — cortex provision <agent>" for agents that
# were correctly registered, sending you round a re-provision loop that could never fix it. Observed
# live 2026-08-06: all 12 REL agents flagged while `buzz channels members` listed every one of them.
# It also only ever worked against a LOCAL relay with dev credentials — a hosted relay has no
# reachable Postgres — whereas the CLI works for both.
is_channel_member() {
  [ -f "$BUZZ_OWNER_ENV" ] || return 1
  # shellcheck disable=SC1090
  ( . "$BUZZ_OWNER_ENV"
    BUZZ_RELAY_URL="${BUZZ_RELAY_HTTP:-http://localhost:3000}" BUZZ_PRIVATE_KEY="$SEC" \
      "$(buzz_cli)" channels members --channel "$1" 2>/dev/null ) | grep -q "\"$2\""
}

# Does the RELAY agree that this agent is owned by the identity we watch from?
#
# The Activity panel is gated on the relay's own record, not on the agent's profile: NIP-AO says
# "Relay MUST verify is_agent_owner(agent, owner)" before fanning out a kind:24200 telemetry frame.
# That record (`users.agent_owner_pubkey`) is FIRST-MINT-WINS and IMMUTABLE, so a wrong value is
# permanent for that keypair and re-attesting is a silent no-op. Surfaced here because the failure is
# otherwise invisible: agent healthy, turn runs, reply posts, panel eternally empty, nothing logged.
# Does the agent's PUBLISHED channel list still match its LIVE membership?
#
# `channel_ids` in the kind:10100 directory record is a snapshot taken at publish time, and nothing
# refreshes it — not buzz-acp (it never writes 10100), not the relay (it reads only
# channel_add_policy), not Desktop (it treats the record as "near-static"). So adding an agent to a
# channel through the UI leaves the record wrong, which breaks the agent's profile channel list, the
# Activity panel's channel resolution, and mention eligibility — while the AGENT itself is fine,
# having joined the channel live off a membership notification. That asymmetry is why the symptom
# reads as "the agent doesn't know it's in the channel". Warn, don't fail: the fix is one command.
agent_directory_fresh() {
  local a="$1" pub sec live published
  [ -f "$(agent_env "$a")" ] || return 0
  # shellcheck disable=SC1090
  pub="$(sed -n 's/^PUB=//p' "$(agent_env "$a")" | head -1)"
  sec="$(sed -n 's/^SEC=//p' "$(agent_env "$a")" | head -1)"
  [ -n "$pub" ] && [ -n "$sec" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0

  live="$(docker exec buzz-postgres psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
    "SELECT count(*) FROM channel_members WHERE pubkey=decode('$pub','hex');" 2>/dev/null | tr -d '[:space:]')" || return 0
  published="$(docker exec buzz-postgres psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
    "SELECT json_array_length((content::json->'channel_ids')) FROM events
      WHERE kind=10100 AND pubkey=decode('$pub','hex') AND deleted_at IS NULL LIMIT 1;" 2>/dev/null | tr -d '[:space:]')" || return 0
  [ -n "$live" ] && [ -n "$published" ] || return 0

  if [ "$live" = "$published" ]; then
    ok "    directory record current ($published channel(s))"
  else
    warn "    directory STALE — in $live channel(s), record lists $published: cortex sync-directory $a"
  fi
}

# Does this agent have the MCP logins the human already performed?
#
# `cursor-agent` keys MCP OAuth by PROJECT — a slug of the CWD — and every agent runs from its own
# dir, so a human's `cursor-agent mcp login <server>` authenticates their shell and NOT ONE AGENT.
# The agent then reports "<server>: requires_authentication" for a server that is demonstrably
# logged in, which reads as a broken login rather than a scoping rule. Warn (not fail): plenty of
# instances use no authenticated MCP server at all.
agent_mcp_auth_ok() {
  local projects="${CURSOR_HOME:-$HOME/.cursor}/projects" slug
  [ -d "$projects" ] || return 0                     # not a cursor-agent runtime — nothing to check
  # Any auth at all configured on this machine? If not, there is nothing to be missing.
  ls "$projects"/*/mcp-auth.json >/dev/null 2>&1 || return 0
  slug="$(printf '%s' "${INSTANCE#/}/.cortex/agents/$1" | tr -c 'A-Za-z0-9' '-')"
  if [ -f "$projects/$slug/mcp-auth.json" ]; then
    ok "    MCP auth present"
  else
    warn "    no MCP auth for this agent — cortex sync-mcp-auth (auth is per-CWD; your login covers none)"
  fi
}

observer_owner_ok() {
  local a="$1" pub recorded
  [ -n "${AGENT_OWNER:-}" ] || return 0
  [ -f "$(agent_env "$a")" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  pub="$(sed -n 's/^PUB=//p' "$(agent_env "$a")" | head -1)"
  [ -n "$pub" ] || return 0
  recorded="$(docker exec buzz-postgres psql -U buzz -d buzz -tAc \
    "SELECT COALESCE(encode(agent_owner_pubkey,'hex'),'') FROM users WHERE pubkey=decode('$pub','hex');" \
    2>/dev/null | tr -d '[:space:]')" || return 0
  if [ -z "$recorded" ]; then
    warn "    relay owner unset — attest before first auth, else observer frames drop"
  elif [ "$recorded" = "$AGENT_OWNER" ]; then
    ok "    relay owner matches (observer frames deliverable)"
  else
    bad "    relay owner ${recorded:0:16}… != AGENT_OWNER ${AGENT_OWNER:0:16}… — PERMANENT; rotate this agent's key"
  fi
}

doctor() {
  echo "== doctor =="
  local rt; rt="$(runtime)"
  echo "-- host --"
  for tool in bash python3 curl nc pgrep pkill; do
    command -v "$tool" >/dev/null 2>&1 && ok "$tool" || bad "$tool missing — install it with your OS package manager"
  done
  if [ "$(uname -s)" = "Linux" ]; then
    command -v systemctl >/dev/null 2>&1 && ok "systemctl (Linux service manager)" || warn "systemctl missing — manual start works, systemd services unavailable"
  fi
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
    opencode)         opencode acp --help >/dev/null 2>&1 && ok "opencode acp" || bad "opencode acp unavailable — needs sst/opencode >= 1.1" ;;
    *)                warn "unrecognized runtime $rt — skipping probe" ;;
  esac
  [ -x "$(synapse_bin)" ] && ok "synapse engine (vault)" || bad "synapse not installed in vault — npm i in $SYNAPSE_VAULT"
  [ -x "$(synapse_mcp_bin)" ] && ok "synapse-mcp (vault)" || bad "synapse-mcp missing — needs @eborja/synapse >=0.2 in the vault"

  echo "-- infra --"
  nc -z 127.0.0.1 3000 >/dev/null 2>&1 && ok "relay :3000" || bad "relay down — cortex start-relay (or launchd)"
  # Probe the PORTS, with the client tools only as a bonus. `redis-cli`/`psql` are frequently absent
  # on a dev machine (they are here), so the client-based checks reported "not answering" for
  # services that were perfectly healthy — a warning that means nothing is worse than no warning,
  # because it trains you to ignore this section.
  if redis-cli ping >/dev/null 2>&1; then ok "redis ping"
  elif nc -z 127.0.0.1 6379 >/dev/null 2>&1; then ok "redis :6379"
  else bad "redis down — docker compose up -d redis (in \$BUZZ_REPO)"; fi
  if PGPASSWORD="$PG_PW" psql -h localhost -U "$PG_USER" -d "$PG_DB" -c 'SELECT 1' >/dev/null 2>&1; then ok "postgres query"
  elif nc -z 127.0.0.1 5432 >/dev/null 2>&1; then ok "postgres :5432"
  else bad "postgres down — docker compose up -d postgres (in \$BUZZ_REPO)"; fi
  # Media/object storage. The relay stores every uploaded image here (BUZZ_S3_ENDPOINT), so when it
  # is missing, attachments fail with a bare "relay returned 500 Internal Server Error" in the client
  # and a 5-minutely "storage sweep failed" in the relay log — with nothing pointing at the cause.
  # It is easy to miss because the relay itself starts fine without it: chat works, uploads do not.
  # Observed live 2026-08-10 after the stack was brought up with only postgres+redis.
  if nc -z 127.0.0.1 9000 >/dev/null 2>&1; then ok "media storage :9000"
  else bad "media storage down — image uploads WILL fail with a 500; docker compose up -d minio minio-init"; fi

  echo "-- auth / runtime --"
  case "$rt" in
    claude-agent-acp) claude auth status 2>/dev/null | grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true' && ok "claude logged in" || bad "claude not logged in — claude auth login" ;;
    cursor-agent)     cursor-agent status 2>/dev/null | grep -qi 'Logged in' && ok "cursor-agent logged in" || bad "cursor-agent not logged in — cursor-agent login" ;;
    opencode)         opencode --version >/dev/null 2>&1 && ok "opencode $(opencode --version 2>/dev/null) — providers via ~/.config/opencode/opencode.json" || bad "opencode not runnable" ;;
  esac
  env | grep -q '^BUZZ_ACP_BASE_PROMPT_FILE=' && bad "BUZZ_ACP_BASE_PROMPT_FILE set — role prompts must use SYSTEM only" || ok "BASE prompt unset"
  ok "prompt source: $PROMPT_SOURCE"

  echo "-- addressable agents (roster derived from the vault) --"
  local cid; cid="$(channel_id 2>/dev/null || true)"
  if [ -n "$cid" ]; then ok "#$BUZZ_DEFAULT_CHANNEL_NAME id $cid"
  elif ! nc -z 127.0.0.1 3000 >/dev/null 2>&1; then bad "#$BUZZ_DEFAULT_CHANNEL_NAME unknown — relay down"
  else bad "#$BUZZ_DEFAULT_CHANNEL_NAME missing — create it in Buzz Desktop"; fi

  for a in "${STANDING[@]}"; do
    _idle="$(agent_idle_timeout "$a")"; _maxt="$(agent_max_turn "$a")"
    echo "  [$a]  hub=$(agent_hub "$a") surface=$(agent_surface "$a") model=$(agent_model "$a") workers=$(agent_workers "$a") turn=${_idle}s/${_maxt}s"
    # IDLE >= MAX_TURN means the idle timer can never fire first, so hang detection is gone and the
    # wall-clock cap is the only backstop. Almost always a mistake when raising the budget.
    if [ "$_idle" -ge "$_maxt" ] 2>/dev/null; then
      warn "    idle timeout (${_idle}s) >= max turn (${_maxt}s) — no hang detection; keep idle below max"
    fi
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
    observer_owner_ok "$a"
    agent_mcp_auth_ok "$a"
    agent_directory_fresh "$a"
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
  if systemd_unit_installed relay; then
    systemctl --user start "$(systemd_unit_name relay)" || { bad "start relay (systemd)"; return 1; }
    wait_port_up 3000 12 && { ok "relay started (systemd)"; return 0; }
    bad "relay failed (systemd)"; return 1
  fi
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
  if systemd_unit_installed "$a"; then
    systemctl --user start "$(systemd_unit_name "$a")" || { bad "start $a (systemd)"; return 1; }
    sleep 2
    agent_running "$a" && { ok "started $a (systemd)"; return 0; }
    bad "start $a failed (systemd)"; return 1
  fi
  if [ -f "$LAUNCH_DIR/${LABEL_PREFIX}-$a.plist" ]; then launchctl_ensure "$a" || true; sleep 2
    agent_running "$a" && { ok "started $a (launchd)"; return 0; }; fi
  CORTEX_INSTANCE="$INSTANCE" nohup bash "$LIB/run-agent.sh" "$a" >/dev/null 2>&1 &
  echo $! >"$INSTANCE/logs/$a.pid"; disown $! 2>/dev/null || true; sleep 2
  agent_running "$a" && ok "started $a (nohup)" || { bad "start $a failed"; tail -30 "$INSTANCE/logs/$a.log" || true; return 1; }
}

stop_agent() {
  local a="$1"
  if systemd_unit_installed "$a" && systemctl --user stop "$(systemd_unit_name "$a")" 2>/dev/null; then
    echo "  stopped $a (systemd)"
    return 0
  fi
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
  if systemd_unit_installed relay && systemctl --user stop "$(systemd_unit_name relay)" 2>/dev/null; then
    wait_port_free 3000 || true
    echo "  stopped relay (systemd)"
    return 0
  fi
  [ -f "$LAUNCH_DIR/${LABEL_PREFIX}-relay.plist" ] && { launchctl bootout "gui/$(id -u)/${LABEL_PREFIX}-relay" 2>/dev/null || launchctl unload "$LAUNCH_DIR/${LABEL_PREFIX}-relay.plist" 2>/dev/null || true; }
  [ -f "$INSTANCE/logs/relay.pid" ] && { kill "$(cat "$INSTANCE/logs/relay.pid")" 2>/dev/null || true; rm -f "$INSTANCE/logs/relay.pid"; }
  pkill -f 'buzz-relay' 2>/dev/null || true
  wait_port_free 3000 || true          # block until the drain releases :3000, so a start after us can bind
  echo "  stopped relay"
}

# Emit a LaunchAgent plist for the relay or an agent. All paths absolute; CORTEX_INSTANCE passed in.
write_plist() {
  local kind plist
  kind="$1"
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

# Emit user services for Linux. The source copies stay in the instance so they can be inspected and
# regenerated; systemd loads the installed copies from ~/.config/systemd/user.
write_systemd_unit() {
  local kind unit
  local bash_bin script working q_instance q_script q_working q_bash q_kind
  kind="$1"
  unit="$INSTANCE/systemd/$(systemd_unit_name "$kind")"
  bash_bin="$(command -v bash)"
  if [ "$kind" = "relay" ]; then
    script="$LIB/run-relay.sh"; working="$BUZZ_REPO"
  else
    script="$LIB/run-agent.sh"; working="$INSTANCE"
  fi
  q_instance="$(systemd_quote "$INSTANCE")"
  q_script="$(systemd_quote "$script")"
  q_working="$(systemd_path "$working")"
  q_bash="$(systemd_quote "$bash_bin")"
  q_kind="$(systemd_quote "$kind")"
  mkdir -p "$INSTANCE/systemd" "$SYSTEMD_DIR"
  if [ "$kind" = "relay" ]; then
    cat >"$unit" <<UNIT
[Unit]
Description=Cortex Buzz relay

[Service]
Type=simple
WorkingDirectory=$q_working
Environment=CORTEX_INSTANCE=$q_instance
ExecStart=$q_bash $q_script
Restart=always
RestartSec=2
TimeoutStopSec=45
KillMode=control-group

[Install]
WantedBy=default.target
UNIT
  else
    cat >"$unit" <<UNIT
[Unit]
Description=Cortex Buzz agent $kind

[Service]
Type=simple
WorkingDirectory=$q_working
Environment=CORTEX_INSTANCE=$q_instance
ExecStart=$q_bash $q_script $q_kind
Restart=always
RestartSec=2
TimeoutStopSec=45
KillMode=control-group

[Install]
WantedBy=default.target
UNIT
  fi
  cp "$unit" "$SYSTEMD_DIR/"
  ok "wrote $(systemd_unit_name "$kind")"
}

install_systemd() {
  require_systemd || return 1
  echo "== install systemd user units =="
  write_systemd_unit relay
  for a in "${STANDING[@]}"; do write_systemd_unit "$a"; done
  echo "Load with: cortex systemd-load"
  echo "For boot without login: loginctl enable-linger"
}

systemd_load() {
  require_systemd || return 1
  [ -f "$(systemd_unit_path relay)" ] || { bad "systemd units missing — cortex install-systemd"; return 1; }
  systemctl --user daemon-reload || { bad "systemd user manager unavailable"; return 1; }
  wait_port_free 3000 || true
  systemctl --user enable --now "$(systemd_unit_name relay)" \
    && ok "loaded $(systemd_unit_name relay)" || bad "load relay"
  wait_port_up 3000 12 && ok "relay :3000 ready" || warn "relay not answering yet"
  for a in "${STANDING[@]}"; do
    systemctl --user enable --now "$(systemd_unit_name "$a")" \
      && ok "loaded $(systemd_unit_name "$a")" || bad "load $a"
  done
  return $FAIL
}

systemd_unload() {
  require_systemd || return 1
  for a in "${STANDING[@]}"; do
    systemctl --user disable --now "$(systemd_unit_name "$a")" 2>/dev/null || true
    echo "  unloaded $a"
  done
  systemctl --user disable --now "$(systemd_unit_name relay)" 2>/dev/null || true
  wait_port_free 3000 || true
  echo "  unloaded relay"
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
  # `restart --idle` cycles only agents that are NOT mid-turn, and names the ones it skipped.
  # Config changes (turn budget, workers, model) apply at process START, so rolling one out means
  # restarting — and a blanket `restart all` destroys whatever turns are in flight, silently: the
  # channel simply never gets its answer. This makes "roll out the change without losing live work"
  # one command instead of hand-picking idle agents out of the logs.
  # Accepts an explicit list too: `restart --idle a b c`.
  restart)
    if [ "${1:-}" = "--idle" ]; then
      shift
      _targets=("$@"); [ "${#_targets[@]}" -gt 0 ] || _targets=("${STANDING[@]}")
      _skipped=()
      for _a in "${_targets[@]}"; do
        if agent_busy "$_a"; then _skipped+=("$_a"); continue; fi
        "$LIB/factory.sh" stop "$_a" >/dev/null 2>&1
        "$LIB/factory.sh" start "$_a" >/dev/null 2>&1 && ok "restarted $_a" || bad "restart $_a"
      done
      if [ "${#_skipped[@]}" -gt 0 ]; then
        echo
        warn "mid-turn, left running: ${_skipped[*]}"
        echo "       re-run when they finish:  cortex restart ${_skipped[*]}"
      fi
      exit $FAIL
    fi
    "$LIB/factory.sh" stop "${1:-all}"; "$LIB/factory.sh" start "${1:-all}" ;;
  provision) CORTEX_INSTANCE="$INSTANCE" bash "$LIB/provision-agent.sh" "${1:?usage: cortex provision <name>}" ;;
  # Both run in a child shell because they prompt for / handle secrets and must not inherit or leak
  # this process's exported agent environment.
  attest) CORTEX_INSTANCE="$INSTANCE" bash "$LIB/attest-agent.sh" "$@" ;;
  sync-mcp-auth) CORTEX_INSTANCE="$INSTANCE" bash "$LIB/sync-mcp-auth.sh" "$@" ;;
  sync-directory) CORTEX_INSTANCE="$INSTANCE" bash "$LIB/sync-directory.sh" "$@" ;;
  # Installs the operator MCP plugin INTO the vault, where synapse-mcp discovers it by convention —
  # so every agent briefed from that vault can see operator state without per-machine MCP config.
  install-mcp-plugin)
    dest="$SYNAPSE_VAULT/_meta/mcp-plugins"
    mkdir -p "$dest"
    cp "$LIB/../templates/mcp-plugins/cortex.mjs" "$dest/cortex.mjs"
    echo "  installed $dest/cortex.mjs"
    echo "  restart agents to pick it up:  cortex restart all"
    ;;
  install-launchagents) install_launchagents ;;
  launchd-load) launchd_load; exit $FAIL ;;
  launchd-unload) launchd_unload ;;
  install-systemd) install_systemd ;;
  systemd-load) systemd_load; exit $FAIL ;;
  systemd-unload) systemd_unload ;;
  test-mcp) test_mcp; exit $FAIL ;;
  agents-sync) agents_sync ;;
  *) echo "unknown factory command: $CMD" >&2; exit 2 ;;
esac
