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

## End to end — confirmed in a live session

Enabled in the wrapper on 2026-08-14. A real session's snapshot shadows `grep`,
and a Bash-tool `grep` went through it and returned correct hits, exit 0. The
shim re-execs the binary as ugrep unless the args hit its escape list (`-Z`,
`--null`, `--*-filter*`, `---*`, `-@*` → `command grep`):

```sh
exec -a ugrep "$_cc_bin" -G --ignore-files --hidden -I --exclude-dir=.git ... "$@"
```

Sessions start and idle normally (canary `TTIDLE=9 / 4.1s` on the live wrapper).

## What the shim's flags change

Re-running the differential in that exact configuration agrees much more closely
than bare `ugrep -r` did — `--hidden` puts the dot-directories back in scope:

| pattern | `/usr/bin/grep -rl` | shim | only in grep |
|---|---|---|---|
| `skill` | 209 | 206 | `.git/index` + 2 symlinks |
| `function` | 93 | 91 | 2 symlinks |

`.git` is excluded on purpose, `-I` skips binaries, `--ignore-files` honours
`.gitignore`, and the symlinks are ugrep declining to follow what BSD `grep -r`
follows. Every one of those is Claude Code behaving as designed on any platform.
The point of the table is that **we deviate nowhere** — which is the whole
question this document exists to answer.

## Recommendation

Drop both env vars from the wrapper — done locally, and reported upstream.
Independent of the linkage work; revert is restoring the two exports.
