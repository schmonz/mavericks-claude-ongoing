# Loading avxemu by linkage instead of DYLD_INSERT_LIBRARIES

**It works.** Claude Code 2.1.232 runs a full session with `libavxemu.dylib`
baked into the binary as an `LC_LOAD_DYLIB` and **no `DYLD_*` in the
environment at all** — spin canary `TTIDLE=9, 3.8s CPU`, real em-dash plugin
payloads, same as the inserted configuration.

Getting there needed one non-obvious piece, proven here.

## Why plain linkage isn't enough

avxemu survives an app that installs its own signal handlers by interposing
`sigaction`/`signal` through `__DATA,__interpose` (`handler.c`). **10.9's dyld
registers interposing only for `DYLD_INSERT_LIBRARIES` images.** Link avxemu
instead and that section is ignored, so the app's `sigaction(SIGILL, …)` reaches
libSystem, the app takes the signal the emulator lives on, and emulation dies at
the first faulting instruction. For Claude Code that surfaced as Bun's crash
banner and a hang — nothing to do with load order, which is what we chased first.

`sigtest.c` is the minimal repro: install a SIGILL handler like a crash reporter
would, then execute `vpaddd ymm`.

| avxemu supplied by | result |
|---|---|
| `DYLD_INSERT_LIBRARIES` | `AVX2 emulated fine` — exit 0 |
| linked (ordinal 1) | `MY handler got SIGILL` — exit 42 |
| linked + `shim.c` | `AVX2 emulated fine` — exit 0 |

## The missing piece

`shim.c` does the interposition by hand — the fishhook technique. It walks the
main executable's lazy/non-lazy symbol pointer sections via the indirect symbol
table and repoints the `sigaction`/`signal` slots at `avxemu_sigaction` /
`avxemu_signal`, reaching the same end state dyld would have produced. About 60
lines, no dependencies beyond `<mach-o/*>`.

On the real binary it reports `rebound sigaction=1 signal=1 slot(s)`, and Claude
Code comes up.

## Reproducing

```sh
clang -dynamiclib -O1 -install_name "$PWD/libshim.dylib" shim.c -o libshim.dylib
cp "$(readlink ~/.local/bin/claude)" claude-shim
# needs change_dylib from branch change-dylib-insert-renumber, and the
# __init_offsets fix from branch macho-grow-init-offsets
change_dylib claude-shim -grow \
    -insert "$MF/libavxemu.dylib" -insert "$PWD/libshim.dylib"
# plus the usual @loader_path aliases (libS/libI/libc++) beside the binary
./claude-shim --version
```

## Whether to actually adopt it

This is a proof, not a proposal. The shim belongs inside avxemu if anywhere —
it already patches `cpuid` and `lzcnt` in place, so "if I wasn't inserted,
rebind my own overrides" is in character and would make the dylib work either
way. That is a change to upstream's emulator core, and it buys:

- emulation confined to one binary; no `DYLD_INSERT_LIBRARIES` inherited by
  every child, so no `DYLD_INSERT_LIBRARIES: ""` scrub needed in settings
- immunity to env scrubbing, which is the failure that actually bit us: the
  `find`/`grep` shims re-exec the claude binary with the env cleared, which is
  how embedded bfs came to SIGILL 132
- startup cost unchanged (4.2 ms/run linked vs 4.8 ms inserted on a small
  program; canary 3.8s vs 4.1s CPU)

against: a patch step on every Claude Code update (the wrapper already patches),
header room via `-grow`, and a hard dyld failure rather than a soft one if the
dylib goes missing.

The env var works today and costs one settings line. This is the better design;
it is not an urgent one.
