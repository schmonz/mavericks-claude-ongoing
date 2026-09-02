# `USE_BUILTIN_RIPGREP=0` is load-bearing — the embedded rg SIGBUSes under avxemu

**For:** mavericksforever.com / Wowfunhappy.
**Short version:** keep it. We tried to talk you out of it and were wrong. The
underlying cause is an avxemu limitation, not a ripgrep one, and it has
consequences for the linkage proposal.

## What happens

Claude Code 2.1.251's embedded ripgrep (14.1.1), invoked the way Claude Code
invokes it, dies with **SIGBUS (exit 138)** partway through a large tree — after
emitting a nondeterministic slice of the results:

```
$ DYLD_INSERT_LIBRARIES=$MF/libavxemu.dylib \
    sh -c 'exec -a rg "$0" -l skill ~/.claude/plugins' ~/.local/share/claude/versions/2.1.251
run 1: lines=9  exit=138        run 4: lines=9  exit=138
run 2: lines=21 exit=138        run 5: lines=9  exit=138
run 3: lines=14 exit=138
```

The correct answer is **218** files. Partial output with a zero-ish exit path is
the dangerous part: a search tool that silently returns a third of the matches is
worse than one that refuses to run.

## Root cause: avxemu's live patching is not thread-safe

Two variables isolate it, one at a time:

| configuration | result |
|---|---|
| avxemu inserted, default threads | **SIGBUS, 5/5**, 9–29 of 218 lines |
| avxemu inserted, `rg -j1` | exit 0, **218/218**, 3/3 |
| avxemu inserted, `AVXEMU_RELOC=0` | exit 0, **218/218**, 3/3 |
| no `DYLD_INSERT_LIBRARIES` | exit 0 |

`AVXEMU_RELOC=0` alone fixes it, which points straight at the fault-driven
relocation path — and `reloc.c` says so itself:

> MILESTONE-A LIMITATION (known, deferred): this flips a live `__text` page
> RW->RX and writes the 5-byte jmp WHILE the program runs. In a multithreaded
> target another thread executing this function could observe a half-written jmp
> or the transient RW page, and corrupt. […] do NOT rely on this being safe
> under concurrency.

Relocation is **on by default** (`g_reloc_enabled = 1`). ripgrep is
aggressively multithreaded, so it hits the window reliably; the single-threaded
assumption the patcher was written under does not hold for it.

## The other two embedded tools are fine

Same host, same tree, same avxemu, 5 runs each:

| tool | result |
|---|---|
| `ugrep -r -l` | exit 0, 218/218 every run — agrees with `rg -j1` exactly |
| `bfs … -name '*.md'` | exit 0, 326/326 every run |

So the shell-snapshot shims themselves are healthy on 10.9 — that part of our
earlier note stands. It is specifically the **ripgrep** path that is unsafe,
which is exactly the one `USE_BUILTIN_RIPGREP=0` disables. Your wrapper is right
and we were wrong to question it.

(If you want the `--allowedTools Grep` line for the in-process Grep/Glob tools,
that is a fine reason to keep it — but it does not need to be there to dodge a
crash, and in its current space form it swallows the user's first positional.
See `../mf-wrapper-equals-form/REPORT.md`.)

## Why this matters beyond one env var

**It is a caution for the linkage proposal** (`../mf-installer-link-avxemu/`).
Linking avxemu into the binary means every re-exec of that binary as `rg` —
which is exactly how the embedded ripgrep runs — carries avxemu with it, with no
`DYLD_INSERT_LIBRARIES` for `USE_BUILTIN_RIPGREP=0`-style env hygiene to bypass.
Anything that switches avxemu from inserted to linked should either keep
ripgrep disabled, ship `AVXEMU_RELOC=0`, or make `patch_site_jmp` safe under
concurrency first.

**And the main `claude` process is itself multithreaded** and runs with
relocation enabled. It has been stable here for weeks, presumably because its
AVX2 sites get patched early and are not re-entered from several threads at the
moment of patching. But the guarantee is absent rather than merely unexercised.
Worth knowing when a rare, unreproducible crash report arrives.

## Suggested fixes, cheapest first

1. **Keep `USE_BUILTIN_RIPGREP=0`.** Zero cost, already in place.
2. **Consider defaulting `AVXEMU_RELOC` off** for multithreaded targets, or
   gating relocation to the main thread. The emulate-only path is slower but has
   no live-patch window.
3. **Make `patch_site_jmp` concurrency-safe** if relocation is to stay on by
   default: patch via a scratch mapping and an atomic 8-byte store rather than a
   RW window plus `memcpy`.

## Reproducer

`scripts/avxemu_thread_probe.sh` in our repo, or the one-liner above with
`-j1` / `AVXEMU_RELOC=0` toggled. Measured on OS X 10.9.5, Ivy Bridge,
Claude Code 2.1.251, libavxemu as shipped 2026-08-28.
