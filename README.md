# mavericks-claude-ongoing

Notes from making **Claude Code** work on a **no-AVX2 Mac** (Ivy Bridge, OS X
10.9.5) via the [Mavericks Forever](https://mavericksforever.com) launcher and
`libavxemu`.

**Done.** The startup spin was an avxemu decode bug — the emulator dropped the
`66` operand-size prefix on `lzcnt`/`tzcnt`, so a 16-bit `lzcnt cx,di` came back
16 too high and JavaScriptCore's character-search loop never ended. Correctness,
not speed. The fix and everything else we produced is merged upstream and ships
in the installer, so a fresh install from mavericksforever.com needs nothing from
this repo.

- **`docs/FINDINGS.md`** — the root cause, how it eluded us, and what shipped.
- **`scripts/spin_canary.sh`** — after a Claude Code or avxemu update, confirms
  the hang class is still dead.
- **`scripts/fetch-version.sh <version>`** — fetch a specific Claude Code build.

One local patch is still needed after each `install.sh` run: the wrapper must
pass `--mcp-config=…`/`--settings=…` in equals form, or the variadic
`--mcp-config` eats your first positional argument. See FINDINGS.

Investigation history — harnesses, dead ends, evidence — is in git history.
