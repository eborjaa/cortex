# Contributing to Cortex

Cortex is the **operator** for Synapse standing agents, distributed as the `@eborja/cortex` npm
package. Contributions improve the *harness* — the CLI, the shell scripts, the templates — never
anyone's personal config. Thanks for helping.

## The bar for every PR

1. **`shellcheck` clean** on the shell scripts:
   ```bash
   shellcheck lib/*.sh
   ```
2. **Bash 3.2 compatible.** macOS ships bash 3.2 (2007); it's the floor. No associative arrays
   (`declare -A`), no `${var^^}`, no `mapfile`. Per-agent settings use flat `AGENT_<name>_<FIELD>`
   vars read by indirect expansion — keep to that pattern.
3. **No personal data.** No hardcoded `/Users/...` paths, real channel IDs, agent rosters, or keys in
   `bin/` / `lib/` / `templates/`. Everything instance-specific lives in a user's `factory.config`.
   A quick self-check:
   ```bash
   grep -rInE '/Users/|[0-9a-f]{8}-[0-9a-f]{4}-' bin/ lib/ templates/   # should be empty
   ```
4. **Ships no third-party code.** Cortex *orchestrates* Buzz; it must never vendor or download Buzz
   source or binaries. It shells out to a user-installed `$BUZZ_REPO`.

## Design principles

- **One seam.** All instance config flows through `factory.config`; the package holds no personal
  values. If you add a knob, add it there with a sensible default and document it in the example.
- **Fail loudly.** Missing binaries, missing keys, unresolved vault → a clear error, never a silent
  wrong default. Identity paths are hard-assigned, not `${VAR:-…}`, so ambient env can't hijack them.
- **Idempotent + dry-run first.** `init`/`provision` are safe to re-run; write-actions preview unless
  `--write`. Match that for new commands.
- **Behavior lives in the vault.** Prompts render from `synapse render`; don't reintroduce
  hand-authored prompt content into the package.

## Layout

| Contributable here | Never here |
|---|---|
| `bin/cortex.mjs`, `lib/*.sh`, `lib/*.mjs`, `templates/` | your `factory.config`, real prompts, keys, logs |
| generic defaults + docs | a specific machine's paths, channel IDs, or roster |

## PR flow

1. Fork (or branch off `main`) from a clean state.
2. Make the change; keep it generic and bash-3.2-safe.
3. `shellcheck lib/*.sh`; test `cortex init` into a scratch dir and `cortex doctor`.
4. Open a PR; update `README.md` / `templates/factory.config.example` if behavior changed.
5. Release (maintainer): CHANGELOG promote → `npm version` → `chore: vX.Y.Z` + tag → push → human
   `npm publish --access public`. Agents prepare the release but never run `npm publish` unless the
   human asks with credentials available.

## Maker ≠ checker

Same ethos as Synapse: the actor that writes a change never approves it. Open a PR; a human reviews
and merges.
