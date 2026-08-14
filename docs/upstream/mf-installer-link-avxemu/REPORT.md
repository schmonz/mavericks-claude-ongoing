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

And one thing that becomes *testable* rather than deletable: native file search
(`CLAUDE_CODE_USE_NATIVE_FILE_SEARCH=0`, `USE_BUILTIN_RIPGREP=0`). Both reasons
it was turned off are now addressed — `ugrep`'s SIGSEGV was the
`__init_offsets` loader bug, fixed in `libSystemWrapper.dylib`, and `bfs`'s
SIGILL 132 was a scrubbed child running unemulated, which linkage makes
impossible. Worth an experiment; not worth an assumption.

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
- **Mixed versions.** A `$MF/change_dylib` predating `-insert` will fail the
  patch step. `install.sh` re-downloads the tools on every run, so this only
  bites someone who updates the wrapper without re-running the installer; if
  that worries you, fall back to the old export when the insert-patch fails.
