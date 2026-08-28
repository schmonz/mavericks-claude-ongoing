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
- **`scripts/mf-wrapper-rebase.sh`** — reapply our wrapper edits to whatever
  `install.sh` currently emits.
- **`scripts/fetch-version.sh <version>`** — fetch a specific Claude Code build.
- **`docs/upstream/`** — reports to send Wowfunhappy: the wrapper equals-form fix,
  and switching the installer to attach avxemu by linkage.
- **`docs/linkage-poc/`** — why linkage needed a hand-rolled interposition.

## The local wrapper delta

`install.sh` overwrites `/usr/local/bin/claude`, so three edits have to go back
on afterwards. `scripts/mf-wrapper-rebase.sh` applies all three to the current
upstream wrapper and fails loudly if an anchor has moved:

1. **Equals form for the injected flags.** `--mcp-config <configs...>` and
   `--allowedTools <tools...>` are variadic, so the space form swallows the
   user's first positional — `claude mcp list` dies with "MCP config file not
   found: $PWD/mcp".
2. **Native file search stays on.** Upstream sets `USE_BUILTIN_RIPGREP=0` and
   passes `--allowedTools Grep` to keep the snapshot shims from installing; both
   worked around bfs/ugrep crashes that `libSystemWrapper`'s `init_offsets.c`
   fixed. Rechecked on 2.1.251 — see `docs/native-search-recheck.md`.
3. **`/usr/bin/grep` by path in the patch-detection probe**, which follows from
   (2): with the shim live, bare `grep` is the embedded ugrep, which reports no
   match on binary input, and the false negative re-patches every launch.

Investigation history — harnesses, dead ends, evidence — is in git history.
