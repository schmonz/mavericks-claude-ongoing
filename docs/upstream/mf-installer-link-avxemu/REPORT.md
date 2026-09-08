# MF installer — attach avxemu by linkage instead of `DYLD_INSERT_LIBRARIES`

**For:** mavericksforever.com / Wowfunhappy — the `claude` wrapper `install.sh` emits.

**Needs two things you have merged but not yet rebuilt:** `change_dylib -insert`
(PR #6) and `avxemu-rebind-when-linked`. The artifacts on the CDN are still the
pre-merge builds — byte-identical to what `install.sh` installed here — so the
shipped `change_dylib` has no `-insert` and the shipped `libavxemu.dylib` has no
rebind. Rebuilding both is the only prerequisite left.

## Why: avxemu is not passive, and the env var is inherited by everything

`libavxemu.dylib` is not a trap-and-emulate shim that sleeps until a SIGILL. Its
constructor runs in **every process that loads it** and does two invasive things
at load time:

- **Live code patching.** A length-disassembler pass scans executable pages for
  AVX2/BMI/`lzcnt`/`tzcnt` sites and rewrites them in place with trampolines.
- **Signal interposition.** It takes over `sigaction`/`signal` to own SIGILL.

`DYLD_INSERT_LIBRARIES` is inherited by every child process by design. So every
child gets that treatment, whether or not it needs emulation — and the patching
is **not thread-safe**. `reloc.c` says so itself. `patch_site_jmp` drops
`VM_PROT_EXECUTE` across a whole 4 KB page while it writes 5 bytes as two
stores, so any other thread executing anything on that page faults.

That is not theoretical. Two independent multithreaded victims, same signal,
same cause:

| child | result |
|---|---|
| **`node`** under GC load, bare | clean 3/3 |
| **`node`** under GC load, avxemu inherited | **SIGBUS (138) 3/3** |
| same, `AVXEMU_RELOC=0` (patching off) | clean 3/3 |
| same, `--single-threaded` | clean 2/2 |
| **embedded `rg`**, avxemu inherited | **SIGBUS 5/5**, after printing 4–8 of 260 matches |
| same, `rg -j1` | 260/260, exit 0 |

`node` never needed emulation in the first place — it runs fine bare. The crash
is the emulator *intruding* on a process that never asked for it. (Historically
this surfaced as `malloc: incorrect checksum for freed object` on 2026-06-29;
today it is a SIGBUS, and `AVXEMU_RELOC=0` isolates it either way.)

The partial-output case is the nastier one: a search tool that silently returns a
fraction of its matches is worse than one that refuses.

### So the env var forces a scrub, and the scrub is a blunt instrument

The workaround today is to empty the variable for children in
`~/.claude/settings.json`:

```json
"env": { "DYLD_INSERT_LIBRARIES": "" }
```

That works, and it is what has protected this machine. But:

1. **It is per-machine configuration that is easy to forget.** A machine missing
   that block silently breaks every `node`-spawning tool. We hit exactly that on
   a second box on 2026-06-29.
2. **It is all-or-nothing across the process tree.** It cannot say "not `node`,
   but yes the claude binary" — it removes avxemu from *every* descendant,
   including re-execs of the claude binary itself.
3. **It only covers processes launched through the wrapper.** Anyone running
   `~/.local/bin/claude` directly gets no emulation at all.

Linkage replaces all three with a property of the file. avxemu is attached to
**exactly one binary**, so unrelated children inherit nothing by construction,
the claude binary is always emulated however it was launched, there is no
environment variable to propagate or scrub, and there is nothing for a new
machine to forget. The granularity moves from *process tree* to *binary*, which
is the granularity the problem actually has.

### What linkage does not fix

It does not make the patching thread-safe. It confines the blast radius to
processes that are the claude binary. The embedded `rg` **is** the claude binary
re-exec'd, so it still gets avxemu and still SIGBUSes — see the caution below.

The underlying fix, if you want it, is in `patch_site_jmp`: keep
`VM_PROT_EXECUTE` in the transient protection, and make the 5-byte write one
aligned 8-byte store.

### Not a motivation: the embedded `bfs` / `ugrep`

Worth stating because it is the obvious guess and it is wrong. Those two did
fail on 10.9 — `bfs` SIGILL 132, `ugrep` SIGSEGV 139 — when the shell-snapshot
shims re-exec the binary under a different `argv[0]`. **They did not need
avxemu.** The cause was 10.9's dyld skipping their `__TEXT,__init_offsets`
constructor, which left their SIMD CPU-feature dispatch table null; your
`init_offsets.c` in `libSystemWrapper.dylib` fixed it and ships. Measured after
that fix, as the shim invokes them:

| configuration | `bfs` | `ugrep` |
|---|---|---|
| stock binary, no `DYLD_*` (a scrubbed child) | exit 0 | exit 0 |
| stock binary, avxemu inserted | exit 0 | exit 0 |
| binary with avxemu linked in, no `DYLD_*` | exit 0 | exit 0 |

So linkage is not needed for those. It is worth knowing that they are fine
without the emulator, not just with it.

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
-    "$MF/change_dylib" "$T" -strip-lc uuid -strip-lc codesig \
+    "$MF/change_dylib" "$T" -strip-lc uuid -strip-lc codesig $AVXARG \
```

`-insert`, not `-add`: an appended dependency initialises *after* the ones
already there, and the emulator has to be armed first.

The `A.dylib` alias is deliberately made whenever the dylib is available, not
only when `NEED_AVXEMU` is set — a binary already carrying
`@loader_path/../A.dylib` will not launch without it.

## Validated end to end

**2.1.258, from a pristine binary.** Fetched from `downloads.claude.ai`,
checksum `c857db5c…` verified, run through the full pipeline (`patch_macho` →
`add_version_min` → `change_dylib` with `-insert` and the three `-change`s), then
executed with **no `DYLD_*` in the environment at all**:

```
Header pad: 64 bytes available (LC end=2816, first sect=2880)
  Insert [48 bytes]: LC_LOAD_DYLIB @loader_path/../A.dylib (now ordinal 1)
  Renumbered library ordinals: 842 symbol entries + bind streams
$ claude.t1 --version
2.1.258 (Claude Code)
```

**2.1.263, in daily use since 2026-09-08.** This is how the machine writing this
report runs. `lsof` on the live session's process shows `libavxemu.dylib` mapped;
the binary carries `A.dylib` at ordinal 1; an `sh -x` trace of the wrapper
contains zero `export DYLD_INSERT_LIBRARIES` lines. Moving the `A.dylib` alias
aside makes dyld refuse to launch, which is the control proving it is genuinely
loaded by linkage and not by a leftover insertion.

No growing involved, which matters now that you have dropped `-grow` from this
call: `-strip-lc uuid codesig` is the whole budget and it is enough. The
`LC_LOAD_DYLIB` costs 48 bytes and the rewritten 2.1.263 has 96, so it patches
with **48 bytes still spare**. Padding is build-dependent (2.1.251 left 48,
2.1.258 left 96 before the insert), so this is worth re-checking on a build that
leaves less. There is no `-grow` fallback any more, by design — it would refuse
on this binary regardless (PR #11).

Linked and inserted behave the same in normal use — the spin canary is 3.8s
against 3.9s. `avxemu-rebind-when-linked` is what makes that true: build
libavxemu from master instead and the linked binary never finishes `--version`
(killed at 90s, 3/3; the rebind build returns in 2s, 3/3, same tree, same flags,
same patched binary). 10.9's dyld honours `__DATA,__interpose` only for inserted
images, so a linked avxemu loses `sigaction`/`signal` and the app steals SIGILL.
That is not a linkage risk; it is why the branch is a prerequisite rather than a
nicety.

## One caution

**Keep `USE_BUILTIN_RIPGREP=0`.** Linked, avxemu rides into re-execs of the
binary as its embedded `rg` — which is the same SIGBUS as `node` above, and the
one case where linkage's reach is a liability rather than an asset. With that
variable kept, the embedded `rg` is never invoked and linkage is safe today.

`ugrep` and `bfs` are clean, five runs each, linked or not.
