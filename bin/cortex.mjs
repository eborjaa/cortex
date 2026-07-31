#!/usr/bin/env node
// cortex — operator for Synapse standing agents on Buzz.
//
//   cortex init [dir] [--write]     scaffold a new instance (control room)
//   cortex doctor                   health check (binaries, relay, agents, MCP)
//   cortex provision <name>         mint keys + register + join the channel
//   cortex start [all|relay|<name>] launch relay + agents
//   cortex stop  [all|relay|<name>]
//   cortex restart [all|<name>]
//   cortex install-launchagents     write ~/Library/LaunchAgents plists for this instance
//   cortex launchd-load | launchd-unload
//   cortex test-mcp                 drive the vault's synapse-mcp and list its tools
//   cortex status
//
// `init` scaffolds; every other command runs the shell harness (lib/factory.sh), which resolves the
// instance from $CORTEX_INSTANCE or by walking up from the current directory for factory.config.

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = join(HERE, "..", "lib");
const [cmd, ...rest] = process.argv.slice(2);

const SHELL_CMDS = new Set([
  "doctor", "status", "start", "start-relay", "stop", "restart", "provision",
  "install-launchagents", "launchd-load", "launchd-unload", "test-mcp",
]);

if (!cmd || cmd === "--help" || cmd === "-h" || cmd === "help") {
  console.log(`cortex — operator for Synapse standing agents on Buzz

usage: cortex <command> [args]

  init [dir] [--write]          scaffold a new instance (control room)
  doctor                        health check
  provision <name>              mint keys + register + join the channel
  start [all|relay|<name>]      launch relay + agents
  stop  [all|relay|<name>]
  restart [all|<name>]
  install-launchagents          write LaunchAgent plists for this instance
  launchd-load | launchd-unload
  test-mcp                      drive the vault's synapse-mcp, list tools
  status

Runs inside an instance dir (one holding factory.config), or set CORTEX_INSTANCE.
Cortex orchestrates a separately-installed Buzz (Block, Apache-2.0) — it ships none of it.`);
  process.exit(cmd ? 0 : 2);
}

if (cmd === "init") {
  await import(join(LIB, "init.mjs"));
} else if (SHELL_CMDS.has(cmd)) {
  const r = spawnSync("bash", [join(LIB, "factory.sh"), cmd, ...rest], { stdio: "inherit" });
  process.exit(r.status ?? 1);
} else {
  console.error(`cortex: unknown command "${cmd}". Run 'cortex --help'.`);
  process.exit(2);
}
