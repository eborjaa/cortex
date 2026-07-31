#!/usr/bin/env node
// init.mjs — scaffold a new Cortex instance (a "control room" for standing agents).
//
//   cortex init                 # dry-run into the current dir
//   cortex init ~/my-agents --write
//
// Copies the templates the package ships (factory.config.example → factory.config, prompt
// fallbacks, .gitignore), creates logs/ + prompts/ + .cortex/, and writes a package.json that
// depends on @eborja/synapse. Never overwrites — safe to re-run. Dry-run unless --write.

import { cpSync, mkdirSync, existsSync, writeFileSync, readFileSync } from "node:fs";
import { join, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

const PKG = fileURLToPath(new URL("..", import.meta.url));
const TPL = join(PKG, "templates");
const argv = process.argv.slice(2);
const write = argv.includes("--write");
const target = resolve(argv.find((a) => a !== "init" && !a.startsWith("--")) || process.cwd());

const { version } = JSON.parse(readFileSync(join(PKG, "package.json"), "utf8"));

// file-copies (src rel to templates/ → dst rel to instance); never overwrite existing.
const FILES = [
  ["factory.config.example", "factory.config"],
  ["gitignore", ".gitignore"],
];
const DIRS = ["logs", "prompts", ".cortex"];

const planned = [];
const skipped = [];
for (const [src, dst] of FILES) {
  if (!existsSync(join(TPL, src))) continue;
  existsSync(join(target, dst)) ? skipped.push(dst) : planned.push([join(TPL, src), join(target, dst), dst]);
}
const pkgNeeded = !existsSync(join(target, "package.json"));

console.log(`instance: ${target}${existsSync(join(target, "factory.config")) ? "  (already initialized — filling gaps)" : ""}`);
console.log(`source:   @eborja/cortex ${version}\n`);
if (!planned.length && !pkgNeeded) {
  console.log(`Nothing to create — all instance files already present.`);
} else {
  console.log("would create:");
  for (const [, , dst] of planned) console.log(`  + ${dst}`);
  if (pkgNeeded) console.log(`  + package.json`);
  for (const d of DIRS) if (!existsSync(join(target, d))) console.log(`  + ${d}/`);
  if (skipped.length) console.log(`left alone: ${skipped.join(", ")}`);
}

if (!write) { console.log(`\nRe-run with --write to apply.`); process.exit(0); }

mkdirSync(target, { recursive: true });
for (const [src, dst] of planned) { mkdirSync(join(dst, ".."), { recursive: true }); cpSync(src, dst); }
for (const d of DIRS) { const p = join(target, d); if (!existsSync(p)) { mkdirSync(p, { recursive: true }); writeFileSync(join(p, ".gitkeep"), ""); } }
if (pkgNeeded) {
  writeFileSync(join(target, "package.json"), `${JSON.stringify({
    name: "my-cortex-instance", private: true, type: "module",
    description: "Cortex instance — runs Synapse standing agents on Buzz.",
    dependencies: { "@eborja/cortex": `^${version}` },
  }, null, 2)}\n`);
}

console.log(`\nCreated instance in ${relative(process.cwd(), target) || "."}`);
console.log(`
next:
  cd ${relative(process.cwd(), target) || "."}
  npm install                       # installs the cortex CLI
  \$EDITOR factory.config            # set your vault, Buzz repo, roster, per-agent hubs
  npx cortex doctor                 # check binaries / relay / agents
  npx cortex provision <agent>      # mint + register each agent
  npx cortex install-launchagents && npx cortex launchd-load
`);
