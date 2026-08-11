// cortex.mjs — the OPERATOR surface, exposed to agents as MCP tools.
//
// Synapse answers "who is this agent and what does it know"; Cortex answers "is it actually running,
// and what is still missing before it works". A principal agent that can author an agent note but
// cannot see the operator state will confidently report success after step 1 of 4 — the note exists,
// so the work looks done, while nothing runs.
//
// Install with `cortex install-mcp-plugin`, which copies this into <vault>/_meta/mcp-plugins/ where
// synapse-mcp discovers it by convention. It needs CORTEX_INSTANCE in the environment (the agent MCP
// wrappers export it).
//
// DELIBERATELY NOT EXPOSED: attestation. It requires the OWNER's secret key, so it must stay a human
// action at a terminal — `cortex attest <name>`. `cortex_agent_readiness` reports whether it has been
// done, which is the part an agent genuinely needs.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";

const INSTANCE = process.env.CORTEX_INSTANCE || "";

function cortex(args, { timeout = 120_000 } = {}) {
  if (!INSTANCE) throw new Error("CORTEX_INSTANCE is not set — this vault is not attached to a Cortex instance");
  return execFileSync("npx", ["cortex", ...args], {
    cwd: INSTANCE,
    env: { ...process.env, CORTEX_INSTANCE: INSTANCE },
    encoding: "utf8",
    timeout,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

/** The vault IS the roster: an agent note with `addressable: true` is a standing agent. */
function rosterFromVault(VAULT) {
  const dir = join(VAULT, "agents");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".md"))
    .map((f) => {
      const fm = readFileSync(join(dir, f), "utf8").split(/^---$/m)[1] || "";
      return {
        id: f.replace(/\.md$/, ""),
        name: f.replace(/^agent-/, "").replace(/\.md$/, ""),
        addressable: /^addressable:\s*true\s*$/m.test(fm),
      };
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

const asText = (text, isError = false) => ({ isError, content: [{ type: "text", text }] });

export function register(server, { surface, VAULT }) {
  server.registerTool("cortex_list_agents", {
    title: "List standing agents",
    description:
      "The operator's roster: every agent note in the vault, which ones are `addressable: true` "
      + "(i.e. an operator will actually run them), and whether each is currently up. "
      + "Use this — not the vault alone — to answer 'is my agent running?'.",
    inputSchema: {},
  }, async () => {
    const roster = rosterFromVault(VAULT);
    let status = "";
    try {
      status = cortex(["status"]);
    } catch (err) {
      status = `(cortex status unavailable: ${err.message})`;
    }
    const lines = roster.map((a) => {
      const flag = a.addressable ? "standing" : "persona (never started — no `addressable: true`)";
      const up = new RegExp(`\\b${a.name}\\b.*\\bup\\b`).test(status) ? "up"
        : new RegExp(`down\\s+${a.name}\\b`).test(status) ? "DOWN" : "?";
      return `  ${a.name.padEnd(22)} ${flag}${a.addressable ? ` · ${up}` : ""}`;
    });
    return asText(`${roster.length} agent note(s) in ${VAULT}/agents:\n${lines.join("\n")}\n\n--- cortex status ---\n${status}`);
  });

  server.registerTool("cortex_agent_readiness", {
    title: "What is still missing for an agent to work",
    description:
      "Checks the steps that fail SILENTLY after an agent note exists: is it addressable, is it "
      + "provisioned, is it attested (owner attestation — without it the agent chats fine but its "
      + "activity is invisible to clients), and does it have MCP auth. Run this before reporting "
      + "that a newly created agent is ready.",
    inputSchema: { name: z.string().describe("Agent name without the agent- prefix") },
  }, async ({ name }) => {
    const roster = rosterFromVault(VAULT);
    const entry = roster.find((a) => a.name === name || a.id === name);
    const out = [];

    if (!entry) return asText(`No agent note for "${name}" in ${VAULT}/agents — create it first with synapse_create_agent.`, true);
    out.push(entry.addressable
      ? "  ok    addressable: true — the operator will run it"
      : "  MISS  not addressable — add `addressable: true` or no operator will ever start it");

    const keyfile = join(process.env.HOME || "", ".config/buzz/agents", `${entry.name}.env`);
    if (!existsSync(keyfile)) {
      out.push(`  MISS  not provisioned — run: cortex start ${entry.name}`);
    } else {
      out.push("  ok    provisioned (keyfile present)");
      const kf = readFileSync(keyfile, "utf8");
      out.push(/^BUZZ_AUTH_TAG=/m.test(kf)
        ? "  ok    attested (owner attestation present)"
        : `  MISS  NOT attested — a human must run: cortex attest ${entry.name}\n`
          + "        Until then the agent replies normally but its Activity panel stays EMPTY,\n"
          + "        and nothing logs the omission. Do not report this agent as ready.");
    }

    const projects = join(process.env.HOME || "", ".cursor/projects");
    const slug = join(INSTANCE, ".cortex/agents", entry.name).replace(/^\//, "").replace(/[^A-Za-z0-9]/g, "-");
    const authFile = join(projects, slug, "mcp-auth.json");
    out.push(existsSync(authFile)
      ? `  ok    MCP auth present (${Object.keys(JSON.parse(readFileSync(authFile, "utf8"))).join(", ") || "none"})`
      : "  MISS  no MCP auth for this agent — run: cortex sync-mcp-auth\n"
        + "        (auth is stored per CWD; a human's `mcp login` covers no agent)");

    return asText(`readiness for ${entry.name}:\n${out.join("\n")}`);
  });

  server.registerTool("cortex_doctor", {
    title: "Operator health check",
    description: "Full Cortex health check: binaries, relay/redis/postgres/media-storage ports, per-agent state.",
    inputSchema: {},
  }, async () => {
    try {
      return asText(cortex(["doctor"]));
    } catch (err) {
      // doctor exits non-zero when it finds problems — that output IS the answer, not a failure.
      return asText(err.stdout || err.message, false);
    }
  });

  // ── writes: full surface only, mirroring synapse_create_* ────────────────────────
  if (surface !== "full") return;

  server.registerTool("cortex_start_agent", {
    title: "Start (and provision) a standing agent",
    description:
      "Provisions if needed, then launches the agent. Proposes by default — pass write:true to run. "
      + "Starting is NOT the last step: call cortex_agent_readiness afterwards, because attestation "
      + "and MCP auth are separate and fail silently.",
    inputSchema: {
      name: z.string().describe("Agent name without the agent- prefix"),
      write: z.boolean().optional().describe("false (default) proposes; true actually starts it"),
    },
  }, async ({ name, write }) => {
    const roster = rosterFromVault(VAULT);
    const entry = roster.find((a) => a.name === name || a.id === name);
    if (!entry) return asText(`No agent note for "${name}" — create it first.`, true);
    if (!entry.addressable) {
      return asText(`"${name}" is not \`addressable: true\`, so the operator has no roster entry for `
        + "it. Add the flag to the agent note first.", true);
    }
    if (!write) return asText(`PROPOSED (nothing started). Re-call with write:true to run:\n  cortex start ${entry.name}`);
    try {
      return asText(`${cortex(["start", entry.name])}\n\nNext: cortex_agent_readiness("${entry.name}") — attestation and MCP auth are separate steps.`);
    } catch (err) {
      return asText(`start failed: ${err.stdout || ""}${err.stderr || err.message}`, true);
    }
  });

  server.registerTool("cortex_sync_mcp_auth", {
    title: "Sync MCP OAuth to every agent",
    description:
      "Copies the MCP OAuth bundles a human authenticated into each agent's per-CWD project store. "
      + "Safe and idempotent. Proposes by default.",
    inputSchema: {
      servers: z.array(z.string()).optional().describe("Server names to sync; omit for all"),
      write: z.boolean().optional().describe("false (default) proposes; true runs it"),
    },
  }, async ({ servers = [], write }) => {
    if (!write) return asText(`PROPOSED. Re-call with write:true to run:\n  cortex sync-mcp-auth ${servers.join(" ")}`.trim());
    try {
      return asText(cortex(["sync-mcp-auth", ...servers]));
    } catch (err) {
      return asText(`sync failed: ${err.stdout || ""}${err.stderr || err.message}`, true);
    }
  });
}
