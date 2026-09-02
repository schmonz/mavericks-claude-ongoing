# MF installer — attach avxemu by linkage instead of DYLD_INSERT_LIBRARIES

**For:** mavericksforever.com / Wowfunhappy — the `claude` wrapper emitted by
`claude/install.sh`.
**Depends on** three changes landing first (branches on
`Mavericks-Porting-Resources`): `avxemu-rebind-when-linked`,
`change-dylib-insert-renumber`, `macho-grow-init-offsets`. Do not apply this
without all three; the second and third are what make a linked, grown binary
load at all.

## Why

`DYLD_INSERT_LIBRARIES` is inherited by every child process, so it has to be
scrubbed back off for them — and a scrubbed child that re-execs the claude
binary then runs *unemulated*. That is not hypothetical: it is how the embedded
`bfs` came to SIGILL 132 in every agent shell, since Claude's native file search
re-execs the binary as `bfs`/`ugrep` from a shell snapshot.

Linked in, the emulator covers exactly the one binary, cannot leak into
children, and survives env scrubbing. It also means anything that runs
`~/.local/bin/claude` directly — a shim, an IDE integration, a script — gets
emulation, where today bypassing the wrapper silently gets none.

Measured on 10.9 / Ivy Bridge, Claude Code 2.1.232, no `DYLD_*` in the
environment at all: full session to idle, spin canary `TTIDLE=9 / 3.8s CPU`
versus `3.9s` for the inserted configuration.

## Verified from a pristine binary

Not from an already-patched copy — 2.1.232 downloaded from
`downloads.claude.ai`, checksum verified against its manifest
(`aa3d606d…`), then run through the complete proposed pipeline:

```
patch_macho     Chained fixups: off=312078336 size=20568
                Exports trie:   off=312098904 size=18128
                Processed 94923 rebases, 1235 binds
                Added LC_DYLD_INFO_ONLY
add_version_min ok
change_dylib    Insert [48 bytes]: LC_LOAD_DYLIB @loader_path/libA.dylib (now ordinal 1)
                Load commands need 40 more bytes than the 16-byte pad; growing header...
                Renumbered library ordinals: 847 symbol entries + bind streams
```

Result: `2.1.232 (Claude Code)`, exit 0, and spin canary `TTIDLE=9 / 3.8s CPU`.

Two things that shipping binary settles. It carries
`LC_DYLD_CHAINED_FIXUPS` + `LC_DYLD_EXPORTS_TRIE` + `LC_BUILD_VERSION` and **no**
`LC_DYLD_INFO_ONLY`, so `patch_macho`'s conversion — 94923 rebases and 1235
binds rewritten from scratch — already runs on every single update. Whatever
`-insert` adds is a rounding error next to surgery that is already routine. And
its header pad is **16 bytes** against the 40 the new load command needs, which
confirms `-grow` fires on every patch under this scheme rather than
occasionally.

## The wrapper changes

Three edits. First, decide rather than export:

```diff
-# The native binary is built for Haswell (AVX2+FMA+BMI). On older CPUs that lack
-# AVX2 (pre-2013 Macs) those instructions fault; libavxemu.dylib installs a
-# SIGILL handler that traps and emulates them. Loaded only when AVX2 is absent,
-# so AVX2-capable Macs keep running natively at full speed. Decided after the
-# bootstrap above so a freshly-downloaded dylib is picked up on first run.
-if [ -f "$MF/libavxemu.dylib" ] && ! sysctl -n machdep.cpu.leaf7_features 2>/dev/null | grep -qiw AVX2; then
-    export DYLD_INSERT_LIBRARIES="$MF/libavxemu.dylib${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
-fi
+# The native binary is built for Haswell (AVX2+FMA+BMI). On older CPUs that lack
+# AVX2 (pre-2013 Macs) those instructions fault; libavxemu.dylib installs a
+# SIGILL handler that traps and emulates them. It is linked INTO the binary
+# below rather than inserted, so it covers this binary only and is never
+# inherited by child processes. Decided after the bootstrap above so a
+# freshly-downloaded dylib is picked up on first run.
+NEED_AVXEMU=
+if [ -f "$MF/libavxemu.dylib" ] && ! sysctl -n machdep.cpu.leaf7_features 2>/dev/null | grep -qiw AVX2; then
+    NEED_AVXEMU=1
+fi
```

Second, one more alias in `$ALIAS_DIR`, alongside the others:

```diff
 ln -sf "$MF/libc++.1.dylib" "$ALIAS_DIR/c++.1.dylib" || { echo "claude: c++ alias failed" >&2; exit 1; }
+[ -n "$NEED_AVXEMU" ] && { ln -sf "$MF/libavxemu.dylib" "$ALIAS_DIR/A.dylib" || { echo "claude: A alias failed" >&2; exit 1; }; }
```

`@loader_path/../A.dylib` is the same length as the `S`/`I`/`c++` install names
you already write, so it costs one load command and no extra name bytes.

Third, insert the load command, and notice when it is missing:

```diff
-if ! head -c 1048576 "$REAL" 2>/dev/null | grep -qE '@loader_path/\.\./S\.dylib'; then
+lc_has() { head -c 1048576 "$REAL" 2>/dev/null | grep -qE "$1"; }
+if ! lc_has '@loader_path/\.\./S\.dylib' ||
+   { [ -n "$NEED_AVXEMU" ] && ! lc_has '@loader_path/\.\./A\.dylib'; }; then
     echo "claude: patching $(basename "$REAL")..." >&2
     T="$REAL.mf-tmp.$$"
     trap 'rm -f "$T"' EXIT INT TERM
     "$MF/patch_macho"     "$REAL" "$T" >/dev/null || { echo "claude: patch_macho failed"     >&2; exit 1; }
     "$MF/add_version_min" "$T"         >/dev/null || { echo "claude: add_version_min failed" >&2; exit 1; }
-    "$MF/change_dylib"    "$T" -grow -strip-lc uuid -strip-lc codesig \
+    AVXARG=""
+    [ -n "$NEED_AVXEMU" ] && AVXARG="-insert @loader_path/../A.dylib"
+    "$MF/change_dylib"    "$T" -grow -strip-lc uuid -strip-lc codesig $AVXARG \
         -change "/usr/lib/libSystem.B.dylib"  "@loader_path/../S.dylib" \
```

`$AVXARG` is intentionally unquoted (two words, no spaces). `-insert` places the
load command ahead of the existing ones and renumbers the library ordinals;
`-add` would not do, because an appended dependency initializes after the ones
already there and avxemu has to be armed first.

## What this lets you delete

- **`DYLD_INSERT_LIBRARIES: ""` in settings.** Nothing sets the variable any
  more, so nothing has to scrub it back off for children. Users who added it
  (or an older managed `settings.json` that carried it) can drop it outright.
  **But note what the scrub is also doing today:** it keeps avxemu out of the
  embedded ripgrep, which SIGBUSes under it (see below). Dropping the scrub is
  only safe alongside one of the mitigations listed at the end of this section.
- **The env export itself**, above.

**Native file search can partly go back on** — and this part does *not* wait for
linkage. Read the caveat at the end of this section first: it applies to the
embedded ripgrep only, and it does not go back on. Measured on 2.1.232 (see `../../native-search-recheck.md`): both
embedded tools now run correctly in every configuration, including the scrubbed
child that historically broke, because `ugrep`'s SIGSEGV was the
`__init_offsets` loader bug that `libSystemWrapper.dylib` already fixes. So
`CLAUDE_CODE_USE_NATIVE_FILE_SEARCH=0` and `USE_BUILTIN_RIPGREP=0` can come out
of the wrapper independently of everything else here. What linkage adds is that
a re-exec'd shim is emulated *by construction* rather than by luck.

Rechecked on 2.1.251 against the `MF_GEN=2` wrapper: invoked exactly as the shim
does (`argv[0]` = `ugrep` / `bfs`), both tools exit 0 and return correct results
— with avxemu inserted, and in a scrubbed child with no `DYLD_*` at all. If the
`--allowedTools` line is there to dodge a crash rather than for the in-process
Grep/Glob, it can go; if it stays, it needs the `=` form (see
`../mf-wrapper-equals-form/REPORT.md`).

**`USE_BUILTIN_RIPGREP=0` must stay, and this is a caution for linkage.** The
embedded ripgrep is heavily multithreaded and SIGBUSes under avxemu, 5 runs out
of 5, emitting a nondeterministic fraction of the correct results first;
`AVXEMU_RELOC=0` or `rg -j1` makes it clean. The cause is the live-patching
limitation `reloc.c` documents for itself. Full measurements in
`../mf-embedded-rg-threads/REPORT.md`.

That matters here because **linkage changes who carries avxemu**, and it is
worth being precise about which way:

- **Unrelated children** — `bash`, `git`, `node`, anything Claude Code spawns
  that isn't itself — stop carrying avxemu entirely, because there is no
  `DYLD_INSERT_LIBRARIES` to inherit. This is the whole point of linkage, and it
  is what lets the `DYLD_INSERT_LIBRARIES: ""` scrub go away.
- **Re-execs of the binary itself** — the embedded `rg`, `ugrep` and `bfs`, which
  run as the same binary under a different `argv[0]` — now carry avxemu
  unconditionally, with no env to scrub them with.

So linkage does not remove the rg exposure; it removes the *ability to opt out of
it by environment*. The good news is that no fix is needed for linkage to be
adopted, because **`USE_BUILTIN_RIPGREP=0` already means the embedded ripgrep is
never invoked** — and on this platform the external native ripgrep is ~60x
faster anyway. Keep that env var and linkage is safe to adopt as far as search
tools are concerned; `ugrep` and `bfs` are verified clean under avxemu.

The residual risk to state honestly: `ugrep` is also capable of running
multithreaded, and it passed 5/5 here rather than being proven safe by
construction. If `patch_site_jmp` is ever made concurrency-safe (see the report
above for the two specific races), that residual goes away and the embedded
ripgrep becomes usable too — though still slower than the native one.

## Risks worth stating plainly

- **`-strip-lc` already buys exactly enough room — with nothing to spare.**
  Measured on 2.1.251 patched by the current `MF_GEN=2` wrapper (`-grow
  -strip-lc uuid -strip-lc codesig` plus the three `-change` rewrites): the image
  base was never lowered, and the patched header has **48 bytes of padding left**
  between the end of the load commands (0xa90) and the first section (0xac0).
  One `LC_LOAD_DYLIB` for `@loader_path/../A.dylib` is 24 bytes of struct plus a
  24-byte 8-aligned name = **exactly 48**. So on this build linkage costs no
  growth at all.

  It fits with zero margin, though, which is the part to plan around: one more
  load command upstream, a couple of bytes less padding in a future build, or a
  longer alias name, and `-grow` is back in the path. That keeps
  `macho-grow-init-offsets` a hard prerequisite rather than an optional extra —
  without it a grown binary dies in the loader on every build ≥ 2.1.229. Worth
  re-running the measurement on whatever build you ship.
- **Failure becomes hard rather than soft.** If `$MF/libavxemu.dylib` goes
  missing, dyld refuses to launch the binary instead of running it unemulated
  until the first AVX2 instruction. Arguably better — a clear loader error beats
  a mystery SIGILL — but it is a change in behaviour. The wrapper recreates the
  alias on every launch, and `install.sh` re-downloads the dylib, so both normal
  repair paths still work.
- **Chained fixups are already handled, and this does not change that.**
  `change_dylib`'s renumbering refuses on `LC_DYLD_CHAINED_FIXUPS`, whose import
  table carries library ordinals of its own — but it never meets one, because
  `patch_macho` runs first in the same pipeline and exists precisely to convert
  chained fixups into `LC_DYLD_INFO_ONLY` (it is idempotent, so it passes an
  already-converted binary straight through). The refusal is belt-and-braces for
  anyone running `change_dylib` standalone.
- **Mixed versions.** A `$MF/change_dylib` predating `-insert` will fail the
  patch step. `install.sh` re-downloads the tools on every run, so this only
  bites someone who updates the wrapper without re-running the installer; if
  that worries you, fall back to the old export when the insert-patch fails.
