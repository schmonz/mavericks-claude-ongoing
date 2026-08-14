# Native file search on 10.9, rechecked (2026-08-14, Claude Code 2.1.232)

Claude Code's native file search rewrites each shell snapshot to shadow `grep`
and `find` with functions that re-exec the claude binary as its embedded
**ugrep** / **bfs**. Both used to fail on 10.9 — bfs `SIGILL 132`, ugrep
`SIGSEGV 139` — so the wrapper disables the feature
(`CLAUDE_CODE_USE_NATIVE_FILE_SEARCH=0`, `USE_BUILTIN_RIPGREP=0`).

**Both failures are gone.** Re-run them and they work.

## Do they still crash?

Invoked exactly as the snapshot shim does (`argv[0]` = `bfs` / `ugrep`):

| configuration | bfs | ugrep |
|---|---|---|
| stock binary, no `DYLD_*` (a scrubbed child) | exit 0 | exit 0 |
| stock binary, avxemu inserted | exit 0 | exit 0 |
| binary with avxemu linked in, no `DYLD_*` | exit 0 | exit 0 |

The credit goes to `init_offsets.c` in `libSystemWrapper.dylib`, not to
anything about how avxemu is attached: both tools have a static constructor in
`__TEXT,__init_offsets` that initializes their SIMD CPU-feature dispatch table,
10.9's dyld skipped it, and the null pointer that left was the crash. That fix
is already shipping.

## Are they *correct*?

Crashing is the easy failure to notice. Differential run over
`~/.claude/plugins/cache` (375 files, wide punctuation restored):

- **bfs vs `/usr/bin/find`**, all files: **375 = 375, identical.**
- **ugrep vs `/usr/bin/grep`**, per-file match counts across 60 `.md` files:
  **0 mismatches.**
- **ugrep vs `/usr/bin/grep`**, recursive file lists: 22 files that grep reports
  and ugrep doesn't, 0 the other way. All 22 are explained by tool defaults,
  not by this platform: 20 live in hidden directories (`.git/`,
  `.claude-plugin/`), which ugrep skips unless asked, and the last 2 are
  **symlinks**, which BSD `grep -r` follows and ugrep doesn't without `-R`.
  You would see the same on a modern Mac.

## End to end

A session launched with native search enabled starts and idles normally
(canary `TTIDLE=9 / 3.9s`). The snapshot-shim path itself was exercised
incidentally today: a `find` shim written into this machine's own session
snapshot ran through the Bash tool and returned the right answer, exit 0.

The one link not exercised in isolation is Claude Code writing a snapshot that
shadows **`grep`** specifically and then using it — the canary never runs a Bash
tool, so no snapshot is generated. Flipping the flag and running one `grep` in
a normal session covers it, and the failure mode if it regresses is loud
(nonzero exit), not silent.

## Recommendation

Drop both env vars from the wrapper. Independent of the linkage work; revert is
one line if anything surprises us.
