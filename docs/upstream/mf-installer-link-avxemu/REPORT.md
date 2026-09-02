# MF installer — attach avxemu by linkage instead of `DYLD_INSERT_LIBRARIES`

**For:** mavericksforever.com / Wowfunhappy — the `claude` wrapper `install.sh` emits.
**Needs all three merged first:** `macho-grow-init-offsets`,
`change-dylib-insert-renumber`, `avxemu-rebind-when-linked`.

`DYLD_INSERT_LIBRARIES` leaks into every child process, so it has to be scrubbed
back off — and a scrubbed child that re-execs the claude binary then runs
unemulated. Linked in, avxemu covers exactly one binary, cannot leak, survives
env scrubbing, and also covers anyone running `~/.local/bin/claude` directly
instead of the wrapper.

## The wrapper changes

```diff
-if [ -f "$MF/libavxemu.dylib" ] && ! sysctl -n machdep.cpu.leaf7_features 2>/dev/null | grep -qiw AVX2; then
-    export DYLD_INSERT_LIBRARIES="$MF/libavxemu.dylib${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
-fi
+NEED_AVXEMU=
+if [ -f "$MF/libavxemu.dylib" ] && ! sysctl -n machdep.cpu.leaf7_features 2>/dev/null | grep -qiw AVX2; then
+    NEED_AVXEMU=1
+fi

 ln -sf "$MF/libc++.1.dylib" "$ALIAS_DIR/c++.1.dylib" || { ... }
+[ -n "$NEED_AVXEMU" ] && { ln -sf "$MF/libavxemu.dylib" "$ALIAS_DIR/A.dylib" || { echo "claude: A alias failed" >&2; exit 1; }; }

-if ! head -c 1048576 "$REAL" 2>/dev/null | grep -qE '@loader_path/\.\./S\.dylib'; then
+lc_has() { head -c 1048576 "$REAL" 2>/dev/null | grep -qE "$1"; }
+if ! lc_has '@loader_path/\.\./S\.dylib' ||
+   { [ -n "$NEED_AVXEMU" ] && ! lc_has '@loader_path/\.\./A\.dylib'; }; then
     ...
+    AVXARG=""
+    [ -n "$NEED_AVXEMU" ] && AVXARG="-insert @loader_path/../A.dylib"
-    "$MF/change_dylib" "$T" -grow -strip-lc uuid -strip-lc codesig \
+    "$MF/change_dylib" "$T" -grow -strip-lc uuid -strip-lc codesig $AVXARG \
```

`-insert`, not `-add`: an appended dependency initialises *after* the ones
already there, and the emulator has to be armed first.

## Validated end to end on 2.1.258

Pristine binary from `downloads.claude.ai`, checksum `c857db5c…` verified, run
through the full pipeline (`patch_macho` → `add_version_min` → `change_dylib`
with `-grow -insert` and the three `-change`s), then executed with **no `DYLD_*`
in the environment at all**:

```
Header pad: 64 bytes available (LC end=2816, first sect=2880)
  Insert [48 bytes]: LC_LOAD_DYLIB @loader_path/../A.dylib (now ordinal 1)
  Renumbered library ordinals: 842 symbol entries + bind streams
$ claude.t1 --version
2.1.258 (Claude Code)
```

`-grow` did not fire — 56 bytes needed against 64 available, image base still
`0x100000000`. (Padding is build-dependent: 2.1.251 left 48, 2.1.258 leaves 96
before the insert. When it goes under, `-grow` fires, which is why
`macho-grow-init-offsets` is a prerequisite rather than insurance.)

**`avxemu-rebind-when-linked` is load-bearing, measured:** with A.dylib pointing
at the shipped libavxemu (built from master, no rebind), the same binary
**spins** — 49% CPU, still going at 5m42s on `--version`. Point it at a
rebind-branch build and it returns instantly. Only the dylib changed. Linked,
dyld does not honour `__interpose`, so the runtime's own SIGILL handler displaces
avxemu's and the first emulated instruction never completes.

## One caution

Keep `USE_BUILTIN_RIPGREP=0`. Linked, avxemu also rides into re-execs of the
binary as its embedded `rg`, which is multithreaded and SIGBUSes against
avxemu's live code patching — `patch_site_jmp` drops execute permission on a
whole 4 KB page while it writes, so any other thread executing there faults
(`reloc.c` flags this as a known Milestone-A limitation). `ugrep` and `bfs` are
clean, 5 runs each. With that env var kept, the embedded rg is never invoked and
linkage is safe today; the fix, if you want it, is to keep `VM_PROT_EXECUTE` in
the transient protection and make the 5-byte write one aligned 8-byte store.

## Note

Your shipped `change_dylib` has `-strip-lc`, which is in no branch of the public
repo — so these PRs are against a base that predates it, and `change_dylib.c`
will need reconciling. Happy to rebase once it is pushed.
