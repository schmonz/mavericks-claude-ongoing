# Proposal: make avxemu's live code patching thread-safe

**Status:** filed 2026-09-08, **deferred**. Decide after the `macho_grow` work,
alongside the question of moving avxemu into its own repo — Wowfunhappy has
invited schmonz to take it over, which makes this our call rather than a report
to send him.

**Not urgent for us.** `USE_BUILTIN_RIPGREP=0` already avoids the only victim we
still have, and costs nothing. This is a latent correctness bug in the emulator
that matters to anyone else running it.

## The bug

`libavxemu` rewrites live `__text` while other threads are executing it.
`reloc.c:patch_site_jmp` is twelve lines and has two concurrency hazards:

```c
uintptr_t lo = (uintptr_t)site & ~(uintptr_t)0xfff;
uintptr_t hi = ((uintptr_t)site + 5 + 0xfff) & ~(uintptr_t)0xfff;
vm_protect(task, lo, hi - lo, FALSE, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);
site[0] = 0xE9; { int32_t r32 = (int32_t)srel; memcpy(site + 1, &r32, 4); }
vm_protect(task, lo, hi - lo, FALSE, VM_PROT_READ|VM_PROT_EXECUTE);
```

1. **The page loses `VM_PROT_EXECUTE` for the duration.** Not the 5 bytes — the
   whole 4 KB page, and *two* pages when the site straddles a boundary. Any
   other thread executing anything on those pages faults. This is the dominant
   hazard and why it reproduces every time.
2. **The 5-byte write is two stores.** Another thread can fetch a half-written
   jmp.

## It is not just ripgrep

We knew the embedded `rg` SIGBUSed. Measured 2026-09-08, `node` v24.6.0 running
an allocate/GC-churn loop does too — same signal, same cause, isolated one
variable at a time:

| configuration | node | embedded rg |
|---|---|---|
| bare / no avxemu | clean 3/3 | — |
| avxemu, default | **SIGBUS (138) 3/3** | **SIGBUS 5/5**, 3–12 of 260 matches |
| avxemu, `AVXEMU_RELOC=0` | clean 3/3 | **260/260, exit 0, 3/3** |
| avxemu, single-threaded | clean 2/2 | 260/260, exit 0 |

So it is not a ripgrep quirk: **avxemu breaks any sufficiently multithreaded
process that loads it.** That is the part upstream does not know — Wowfunhappy
has the rg half only.

The partial-output case is the dangerous one. A search tool that silently
returns 4 of 260 matches is worse than one that crashes.

## Would fixing it make the embedded rg work?

**Almost certainly yes.** With patching disabled and full multithreading, rg is
260/260 exit 0, 3/3 — the emulation, the SIGILL handling and the concurrency are
all fine. The only differences between that configuration and a fixed patcher
are the two hazards above. It is a prediction until built, and
`scripts/avxemu_thread_probe.sh` already encodes the pass/fail criteria.

## The fix

### 1. Keep the page executable — one flag

Add `VM_PROT_EXECUTE` to the transient protection. **Verified on 10.9**: a
`__TEXT` page accepts `RWX|COPY`, stays callable while writable, and the write
lands. This alone removes the hazard that actually fires.

### 2. One aligned store instead of two

x86-64 guarantees atomicity for naturally-aligned stores up to 8 bytes. Read the
aligned 8-byte word containing the site, splice in the 5 jmp bytes, store once.
Requires the 5 bytes to sit inside one aligned word (`site & 7 <= 3`); decline
otherwise. Verified working.

### 3. A thread already inside the window — a judgment call

Neither fix helps if another thread's RIP is already inside `(site, site+5)`.

Worth noticing: **the code already guards the static half of this.**
`avxemu_patch_safe(site, 5)` scans for inbound branch targets landing inside the
footprint and declines if it cannot prove there are none, with the comment
*"Declining here is the safe floor — we never trade correctness for speed."*
That is exactly the prove-it-or-refuse contract we wrote for `macho_grow`. What
is missing is applying the same doctrine to the dynamic case. Options:

- **(a)** Accept it. Fix 2 shrinks the window to a single store, and a thread
  can only be at an interior boundary having just come through the SIGILL
  handler. Cheapest; needs an argument, not just a shrug.
- **(b)** `task_threads` + `thread_suspend` for the swap. Airtight, heavy, and
  a new failure mode of its own if a suspended thread holds a lock the patcher
  needs.
- **(c)** The `int3` two-phase technique: write `0xCC` (one atomic byte), patch
  bytes 2–5, then swap in `0xE9`, catching stragglers in the handler avxemu
  already owns. Standard, and the infrastructure is there.

Measure before choosing. Fixes 1 and 2 are perhaps 40 lines plus a stress test;
fix 3 is the only open design question.

## Is it worth doing at all

Relocation buys **~11%** on the spin canary (4.2s with, 4.7s without) and
**nothing measurable on rg** (2.05s either way). So:

| option | cost | embedded rg |
|---|---|---|
| `USE_BUILTIN_RIPGREP=0` (today) | none | never invoked |
| `AVXEMU_RELOC=0` in the wrapper | ~11% slower Claude Code | works |
| fix the patcher | ~40 lines + a design call | works, no slowdown |

We are fine either way; linkage already keeps avxemu out of `node` and every
other unrelated child, and `USE_BUILTIN_RIPGREP=0` covers the one victim left.
The reason to do it is that it is a real bug in a component we may be about to
own, it has a verified-feasible fix, and it would let us drop a workaround
rather than carry it.

It is also a good first piece of work for a standalone avxemu repo: small,
self-contained, genuinely improves correctness, and `avxemu_thread_probe.sh`
plus `build.sh` step 8 give it a regression test on day one.

## Loose end

`scripts/avxemu_thread_probe.sh` supplies avxemu via `DYLD_INSERT_LIBRARIES`.
Now that our binary has it **linked**, that double-loads the emulator. Fixed
2026-09-08 to detect the linked case and skip the insertion; re-check it if the
attachment method changes again.
