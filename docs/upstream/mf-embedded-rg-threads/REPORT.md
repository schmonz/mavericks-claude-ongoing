# `USE_BUILTIN_RIPGREP=0` is load-bearing — the embedded rg SIGBUSes under avxemu

**For:** mavericksforever.com / Wowfunhappy.
**Short version:** keep it. We were about to suggest you drop it; we were wrong.

## Symptom

Claude Code's embedded ripgrep, invoked as Claude Code invokes it, dies with
**SIGBUS (138)** partway through a large tree — after printing a
nondeterministic slice of the matches:

```
run 1: lines=8   exit=138        run 4: lines=260 exit=0
run 2: lines=4   exit=132        run 5: lines=5   exit=138
run 3: lines=5   exit=138
```

The correct answer is 260. Partial output is the dangerous part: a search tool
silently returning a fraction of the matches is worse than one that refuses.

## Cause

avxemu's live code patching is not thread-safe, and `reloc.c` says so itself
("do NOT rely on this being safe under concurrency"). `patch_site_jmp`:

```c
vm_protect(task, lo, hi - lo, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
site[0] = 0xE9; { int32_t r32 = (int32_t)srel; memcpy(site + 1, &r32, 4); }
vm_protect(task, lo, hi - lo, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
```

1. **Execute permission is dropped for the duration**, across a whole 4 KB page —
   not just the 5 bytes. Any other thread executing *anything* on that page
   faults. This is almost certainly the one doing the damage.
2. The 5-byte write is two stores, so a thread can fetch a half-written jmp.

Relocation is on by default (`g_reloc_enabled = 1`) and ripgrep is heavily
multithreaded, so it hits the window reliably.

Isolating it, one variable at a time:

| configuration | result |
|---|---|
| avxemu inserted, default | **SIGBUS/SIGILL 3/3**, 4–8 of 260 |
| avxemu inserted, `rg -j1` | 260/260, exit 0 |
| avxemu inserted, `AVXEMU_RELOC=0` | 260/260, exit 0 |
| no `DYLD_INSERT_LIBRARIES` | 260/260, exit 0 |

`ugrep` and `bfs` are fine — 5 runs each, 260/260 and 372/372, matching ripgrep
and `/usr/bin/find` exactly. It is specifically ripgrep.

Clearing the faked CPUID bits does **not** help (still crashes 2/3): the binary
is built for Haswell, so AVX2 appears in code that never consults CPUID.

## Fixes, cheapest first

1. **Keep `USE_BUILTIN_RIPGREP=0`.** Already in place, and it is also the faster
   configuration: the emulated embedded rg takes 2.07 s where the external
   native ripgrep does the same search in 0.034 s. ~60x. Not a workaround — the
   better choice on this platform.
2. **Keep `VM_PROT_EXECUTE` in the transient protection** (`READ|WRITE|EXECUTE|COPY`).
   10.9 has no hardened runtime, so RWX is permitted and the page never stops
   being executable.
3. **Make the patch atomic**: one naturally-aligned 8-byte store covering the 5
   bytes and preserving the 3 that follow, rather than two stores. Decline sites
   whose 5 bytes straddle an 8-byte boundary and leave them to the SIGILL path.

We have diagnosed 2 and 3, not implemented them.

## Why it matters beyond one env var

If avxemu is ever **linked** rather than inserted, there is no environment left
to scrub: the embedded rg is the same binary re-exec'd under a different
`argv[0]`, so it carries avxemu unconditionally. `USE_BUILTIN_RIPGREP=0` is then
the only thing standing between you and this crash.

Measured on OS X 10.9.5, Ivy Bridge, Claude Code 2.1.258, libavxemu as shipped
2026-09-02. Reproducer: `scripts/avxemu_thread_probe.sh`.
