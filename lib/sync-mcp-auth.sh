#!/usr/bin/env bash
# sync-mcp-auth.sh — give every standing agent the MCP OAuth you authenticated once, as a human.
#
# WHY THIS IS A FIRST-CLASS COMMAND
# `cursor-agent` stores MCP auth PER PROJECT, keyed by a slug of the CWD:
#     ~/.cursor/projects/<cwd-with-non-alphanumerics-as-dashes>/mcp-auth.json
# Cortex runs each agent from its own scratch dir (.cortex/agents/<name>), so each agent is a
# SEPARATE project as far as the runtime is concerned. `cursor-agent mcp login <server>` in a human
# shell therefore authenticates that shell's directory and NOT ONE AGENT — every agent still reports
# "<server>: requires_authentication", which reads like a broken login rather than a scoping rule.
# Hit live 2026-08-10 with the Atlassian MCP.
#
# The stored entry is a self-contained OAuth bundle (access_token, refresh_token, client_id/secret),
# so copying it between project stores is sufficient — one consent covers every agent, no re-consent.
#
# RUNTIME SCOPE: this is a `cursor-agent` mechanism. Other ACP runtimes (claude-agent-acp, opencode)
# resolve MCP config differently, so the command no-ops harmlessly when the store is absent.
#
# Usage (from an instance dir, or with CORTEX_INSTANCE set):
#   cortex sync-mcp-auth                # every server you have auth for
#   cortex sync-mcp-auth atlassian      # just these
#
# Re-run after authenticating a NEW server, or after adding an agent.
set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$LIB/config.sh"
cortex_load

AGENTS_DIR="$INSTANCE/.cortex/agents"
PROJECTS="${CURSOR_HOME:-$HOME/.cursor}/projects"

[ -d "$PROJECTS" ] || { echo "cortex sync-mcp-auth: no $PROJECTS — nothing to sync (not a cursor-agent runtime?)"; exit 0; }
[ -d "$AGENTS_DIR" ] || { echo "cortex sync-mcp-auth: no agent dirs at $AGENTS_DIR — run 'cortex start all' first" >&2; exit 1; }

python3 - "$AGENTS_DIR" "$PROJECTS" "$@" <<'PY'
import json, os, re, sys

agents_dir, projects = sys.argv[1], sys.argv[2]
wanted = [s for s in sys.argv[3:] if s]

def slug(path):
    # The runtime's own scheme: strip the leading slash, every non-alphanumeric becomes a dash.
    # Verified against existing stores (…/genesis-8.11 -> Users-…-genesis-8-11).
    return re.sub(r'[^A-Za-z0-9]', '-', path.lstrip('/'))

# Newest entry per server wins across all project stores: a re-login writes a fresh bundle, and
# copying a stale one back over it would silently expire the agents days later.
best = {}
for d in os.listdir(projects):
    p = os.path.join(projects, d, "mcp-auth.json")
    if not os.path.exists(p):
        continue
    try:
        data = json.load(open(p))
    except Exception:
        continue
    mtime = os.path.getmtime(p)
    for name, entry in data.items():
        if wanted and name not in wanted:
            continue
        # Plugin auth (plugin-*) is TUI-only — plugins are never loaded in ACP mode, so it is noise.
        if name.startswith("plugin-"):
            continue
        if name not in best or mtime > best[name][0]:
            best[name] = (mtime, entry)

if not best:
    print("no MCP auth found to sync" + (f" for {wanted}" if wanted else "")
          + " — authenticate once first, e.g.:  cursor-agent mcp login <server>")
    raise SystemExit(1)

print("syncing:", ", ".join(sorted(best)))
agents = sorted(a for a in os.listdir(agents_dir) if os.path.isdir(os.path.join(agents_dir, a)))
for agent in agents:
    target = os.path.join(projects, slug(os.path.join(agents_dir, agent)))
    os.makedirs(target, exist_ok=True)
    path = os.path.join(target, "mcp-auth.json")
    cur = {}
    if os.path.exists(path):
        try:
            cur = json.load(open(path))
        except Exception:
            cur = {}
    for name, (_, entry) in best.items():
        cur[name] = entry
    with open(path, "w") as fh:
        json.dump(cur, fh, indent=2)
    os.chmod(path, 0o600)
    print(f"  {agent}: {', '.join(sorted(cur))}")

print(f"\n{len(agents)} agent(s) synced. Restart them to pick the tools up:  cortex restart all")
PY
