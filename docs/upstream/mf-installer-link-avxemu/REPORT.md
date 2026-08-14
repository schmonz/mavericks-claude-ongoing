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

Second, one more alias beside the versioned binary:

```diff
 ln -sf "$MF/libc++abi.1.dylib" "$REAL_DIR/libc++abi.1.dylib" || { echo "claude: libc++abi alias failed" >&2; exit 1; }
+[ -n "$NEED_AVXEMU" ] && { ln -sf "$MF/libavxemu.dylib" "$REAL_DIR/libA.dylib" || { echo "claude: libA alias failed" >&2; exit 1; }; }
```

Third, insert the load command, and notice when it is missing:

```diff
-if ! head -c 1048576 "$REAL" 2>/dev/null | /usr/bin/grep -qE 'libSystemWrapper\.dylib|libS\.dylib'; then
+lc_has() { head -c 1048576 "$REAL" 2>/dev/null | /usr/bin/grep -qE "$1"; }
+if ! lc_has 'libSystemWrapper\.dylib|libS\.dylib' ||
+   { [ -n "$NEED_AVXEMU" ] && ! lc_has 'libA\.dylib'; }; then
     echo "claude: patching $(basename "$REAL")..." >&2
     T="$REAL.mf-tmp.$$"
     trap 'rm -f "$T"' EXIT INT TERM
     "$MF/patch_macho"     "$REAL" "$T" >/dev/null || { echo "claude: patch_macho failed"     >&2; exit 1; }
     "$MF/add_version_min" "$T"         >/dev/null || { echo "claude: add_version_min failed" >&2; exit 1; }
-    "$MF/change_dylib"    "$T" -grow \
+    AVXARG=""
+    [ -n "$NEED_AVXEMU" ] && AVXARG="-insert @loader_path/libA.dylib"
+    "$MF/change_dylib"    "$T" -grow $AVXARG \
         -change "/usr/lib/libSystem.B.dylib"  "@loader_path/libS.dylib" \
```

`$AVXARG` is intentionally unquoted (two words, no spaces). `-insert` places the
load command ahead of the existing ones and renumbers the library ordinals;
`-add` would not do, because an appended dependency initializes after the ones
already there and avxemu has to be armed first.

## What this lets you delete

- **`DYLD_INSERT_LIBRARIES: ""` in settings.** Nothing sets the variable any
  more, so nothing has to scrub it back off for children. Users who added it
  (or an older managed `settings.json` that carried it) can drop it outright.
- **The env export itself**, above.

**Native file search can also go back on** — and this part does *not* wait for
linkage. Measured on 2.1.232 (see `../../native-search-recheck.md`): both
embedded tools now run correctly in every configuration, including the scrubbed
child that historically broke, because `ugrep`'s SIGSEGV was the
`__init_offsets` loader bug that `libSystemWrapper.dylib` already fixes. So
`CLAUDE_CODE_USE_NATIVE_FILE_SEARCH=0` and `USE_BUILTIN_RIPGREP=0` can come out
of the wrapper independently of everything else here. What linkage adds is that
a re-exec'd shim is emulated *by construction* rather than by luck.

## Risks worth stating plainly

- **`-grow` stops being a rare path.** Today it fires only when the rewritten
  names don't fit; after this it fires whenever the extra load command doesn't,
  which on recent builds (2.1.231 ships 16 bytes of header padding) is most of
  them. That makes `macho-grow-init-offsets` a hard prerequisite: without it a
  grown binary dies in the loader on every build ≥ 2.1.229.
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
