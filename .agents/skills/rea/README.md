# rea skill (combined)

One skill for reverse engineering with agents. It merges two approaches:

- **Tier 1, plain shell** (from [leanrea](https://github.com/aicodeking/leanrea)): the fastest CLI command for each target type, paste-and-run recon, and the traps (`rg -uu`, slicing minified files, batching probes). Most questions end here in 2–4 tool calls.
- **Tier 2, the REA MCP server** (from [morluto/rea](https://github.com/morluto/rea)): Ghidra/IDA/Kuna pseudocode, xrefs, call graphs, build comparison, runtime capture and Evidence bundles, used only for the gap the shell can't close.

`references/` is copied verbatim from upstream's `reverse-engineer-anything` skill and refreshed on every sync. `UPSTREAM` records the upstream commit whose `SKILL.md` this skill was last reconciled with.

## Install

```sh
npx skills add fightingentropy/rea --skill rea
```

Tier 2 also needs the REA server: `npm install --global rea-agents`, then `rea setup` for your agent. `rea setup` installs upstream's `reverse-engineer-anything` skill too; remove it afterwards so the two don't compete.

## Sync with upstream

```sh
.fork/sync.sh --push
```

It merges `morluto/rea` main, refreshes `references/`, warns about tools this skill names that no longer exist upstream, and exits with code 2 when upstream's own `SKILL.md` changed and needs porting by hand.
