# Phase 1 — locating & classifying the startup AVX2 hot site

Measurement work for the avxemu fault-driven trampolining plan. Goal: find a
stable hot offset for the startup spin (Claude Code 2.1.185 on this no-AVX2
Ivy Bridge / OS X 10.9.5 Mac) and classify it as **(a)** static image `__TEXT`
(load-time scanner missed it) vs **(b)** a JSC runtime-JIT / anonymous region.

**Verdict up front: (a) STATIC `__TEXT`.** Every hot AVX2 site measured — both
the bulk handled by the load-time trampoline and the remainder trapped via
SIGILL — lives inside the 2.1.185 image `__TEXT`. **No** hot AVX2 was found in
any JIT / anonymous executable mapping. This contradicts the plan's expected
hypothesis (b); it is the more favorable case for the runtime patcher.

## Environment note (a blocker hit and cleared)

The launcher (`scripts/claude_185`) hardcodes
`~/.local/share/claude/versions/2.1.185`, which the autoupdater had reaped
(only `2.1.179` and `2.1.183` remained). Symptom: the harness exits instantly
("`claude: .../2.1.185 does not exist.`"), CPU/TEXT_BASE come back empty, no
spin. Fixed by re-fetching: `sh scripts/fetch-version.sh 2.1.185`
(sha256 `ade7a13c3027f754b4cdac80bcdd6ba470f7becb27cdcf8b6ba9a70cf9e77af7`).

## Method (and why the prescribed one was changed)

`scripts/hot-offset.sh` profiles the thread's **leaf PC** (`profile-1999`,
`@[arg1]`). On this workload that signal is **diffuse and confounded**: the
dominant sample is `pc=0x0` (~75% — the thread is in the `write()` syscall, per
the prior native-sample finding), and the non-zero leaves scatter across static
`__TEXT`, `libavxemu` (the emulator itself), `libicucoreWrapper`, and assorted
anonymous regions. Leaf-PC cannot isolate *where the AVX2 is* because the thread
spends its cycles **inside the emulator**, not at the faulting instruction.

`libavxemu.dylib` exports the SIGILL handler `on_sigill(int, siginfo_t*, void*)`.
For SIGILL, `siginfo_t.si_addr` (offset 24 on x86-64 macOS) **is the faulting
instruction address** — i.e. the AVX2 instruction itself. Histogramming that via
dtrace is the authoritative answer to the static-vs-JIT question:

```
pid$1:libavxemu:on_sigill:entry {
    self->sa = *(uint64_t *)copyin(arg1 + 24, 8);
    @sa[self->sa] = count();
}
tick-4s { exit(0); }
```

(All measurements use a long-lived harness, `/tmp/spin_hold.py`, adapted from
`pyte_watch.py`: it writes the child pid and keeps the spinning process alive
~120s. The stock `catch-spin.sh` + `pyte_type.py` combo kills the child at ~18s,
which races the CPU>70 detection and is why early dtrace/vmmap runs came back
empty. Trust gate set/restored as usual; CPU confirmed >70 before every sample.)

## Which emulation path is hot (3 runs, 4s each)

avxemu has two emulation paths: the **trampoline** (sites the load-time scanner
found in `__TEXT`, patched to call `avxemu_tramp_dispatch` → `tramp_emulate_run`,
no signal) and **SIGILL** (`on_sigill`, for sites the scanner *missed* — the
~57µs trap-and-emulate path). Entry counts:

| run | CPU% | tramp_dispatch / tramp_run | on_sigill | avxemu_emulate (total) | ratio tramp:sigill |
|-----|------|----------------------------|-----------|------------------------|--------------------|
| 1   | 89.9 | 548,765                    | 13,892    | 732,465                | ~39:1              |
| 2   | 100  | 181,002                    | 7,665     | 206,855                | ~24:1              |
| 3   | 95.2 | 678,166                    | 62,766    | 823,058                | ~11:1              |

Takeaways:
- The **trampoline path dominates by count** (11-39×). The load-time scanner
  already found and patched the bulk of the hot AVX2 — and those patched sites
  are static `__TEXT` by construction (the scanner only walks the image).
- The **SIGILL path is still a major wall-time cost**: at ~57µs/trap, run 3's
  62,766 faults ≈ 3.6s of the 4s window; even run 2's 7,665 ≈ 0.4s. SIGILL count
  is bimodal/noisy (warned), but always nontrivial. **The trap is real cost** —
  confirmed.
- `decode` ≈ `on_sigill` each run (decode runs once per missed-site fault);
  `fma_exec` is negligible (49-94).

## Faulting AVX2 instruction addresses — si_addr histogram (3 runs, 4s each)

Top `si_addr` per run, converted to **image-relative offset** (`si_addr -
image __TEXT base`; base differs per run due to ASLR). Every site classified
against that run's live `vmmap`:

**Run A** (base `0x10a970000`, `__TEXT` end `0x10e935000`):

| offset | count | region |
|--------|-------|--------|
| 0x2176a8b | 5643 | STATIC __TEXT |
| 0x2f1e0c4 | 2920 | STATIC __TEXT |
| 0x812a46  |  953 | STATIC __TEXT |
| 0x2177aef |  884 | STATIC __TEXT |
| 0x22587fd |  344 | STATIC __TEXT |
| 0x34484a  |  318 | STATIC __TEXT |
| 0x3447fb  |  304 | STATIC __TEXT |
| 0x379d4a2 |  210 | STATIC __TEXT |

**Run B** (base `0x10a796000`, `__TEXT` end `0x10e75b000`):

| offset | count | region |
|--------|-------|--------|
| 0x32c8865 | 662 | STATIC __TEXT |
| 0x32d6321 | 377 | STATIC __TEXT |
| 0x32d62c8 | 347 | STATIC __TEXT |
| 0x379d4a2 | 312 | STATIC __TEXT |
| 0x32c9284 | 309 | STATIC __TEXT |
| 0x2177aef | 292 | STATIC __TEXT |
| 0x34484a  | 194 | STATIC __TEXT |
| 0x3447fb  | 184 | STATIC __TEXT |

**Run C** (base `0x109850000`, `__TEXT` end `0x10d815000`):

| offset | count | region |
|--------|-------|--------|
| 0x379d4a2 | 334 | STATIC __TEXT |
| 0x2177aef | 269 | STATIC __TEXT |
| 0x34484a  | 154 | STATIC __TEXT |
| 0x3447fb  | 148 | STATIC __TEXT |
| 0x2d5284e |  22 | STATIC __TEXT |
| 0x344b5b  |  21 | STATIC __TEXT |

### Stable offsets (recur in ALL three runs)

- **`0x34484a`** and **`0x3447fb`** — adjacent (Δ = 0x4f = 79 bytes); same hot
  routine, early in the first `__TEXT` segment (~3.4 MB in).
- **`0x2177aef`** — ~35 MB in (first `__TEXT` segment).
- **`0x379d4a2`** — ~58 MB in; this lands in the image's **second** `__TEXT`
  segment (first segment is 55.7 MB: `0x101bf6000-0x1053a4000`; second is
  8.2 MB: `0x1053a4000-0x105bbb000`). A plausible reason the static scanner
  missed it.

Run A additionally had a very hot pair `0x2176a8b` (5643) / `0x2177aef` (884)
— same routine as the cross-run-stable `0x2177aef`. Some per-run offsets vary
(e.g. B's `0x32c8865` cluster), consistent with the bimodal nature, but the set
{`0x34484a`, `0x3447fb`, `0x2177aef`, `0x379d4a2`} is **stable across all 3
runs**. **Stability verdict: STABLE** — a fixed set of static-`__TEXT` offsets.

## Classification: (a) static `__TEXT`

Every top faulting `si_addr` in all three runs falls inside that run's image
`__TEXT` range. None land in `libavxemu`, in a `JS JIT generated code` mapping
(those were 4 KB guard pages, `---/rwx`, no executing code), or in any other
anonymous executable region. The `JS garbage collector` region (1.2 GB) is
non-executable. So:

- The SIGILL-trapped hot AVX2 = a **stable set of static-`__TEXT` sites the
  load-time scanner missed**.
- The trampolined hot AVX2 (the dominant-by-count majority) = static `__TEXT`
  sites the scanner found.
- **No hot AVX2 in JIT / anonymous mappings.** Hypothesis (b) is refuted for
  this workload. (The earlier "anonymous JIT frames in profiling" reading came
  from confounded leaf-PC sampling — see Method.)

Live `vmmap` for reference (one representative spin):
```
__TEXT  0x101bf6000-0x1053a4000 [55.7M] r-x  versions/2.1.185
__TEXT  0x1053a4000-0x105bbb000 [8284K] r-x  versions/2.1.185
__TEXT  0x10f7e3000-0x10f7ee000 [  44K] r-x  libavxemu.dylib
JS JIT generated code  ...4K guard pages, ---/rwx (no live JIT code)
JS garbage collector   0x1fb4ccd000-0x2000000000 [1.2G] ---/rwx (non-exec)
```

## Implication for the runtime patcher (later tasks)

Because the hot faulting sites are **static `__TEXT` at stable offsets**, the
favorable-case robustness assumptions hold:

- **Reach / far-jump island: likely NOT needed.** The avxemu thunk pool sits
  next to the image (`libavxemu` `__TEXT` ~`0x118xxx` vs image ~`0x10axxx`),
  well within `jmp rel32` (±2 GB) of every static `__TEXT` site. The existing
  load-time scanner already patches `__TEXT` in place successfully (proven by
  ~550k trampoline hits/window), so the same reach applies to runtime patching.
- **Code invalidation: likely NOT needed.** Static `__TEXT` is not freed or
  re-JIT'd by JSC, so a once-patched site stays patched. (Contrast the JIT case
  in the plan, which would have required invalidation because JSC reuses/frees
  code — not our situation.)
- **The fix is essentially "do the load-time trampoline patch at runtime, on
  the first SIGILL, for the sites the static scanner missed."** Patch the stable
  missed offsets ({`0x34484a`/`0x3447fb`, `0x2177aef`, `0x379d4a2`}, plus
  whatever else faults) on first fault and subsequent hits take the cheap
  trampoline path instead of the ~57µs trap. A per-site fault counter + hot
  trigger (Task 4) is the right driver; the heavy robustness work (Task 5: reach
  island, invalidation) appears unnecessary for the real hot set, though a cap
  is still cheap insurance.
- Worth investigating separately: **why the static scanner misses these** (the
  `0x379d4a2` site is in the second `__TEXT` segment; others may be reached only
  by indirect control flow). Extending the load-time scanner to cover them would
  avoid the trap entirely without any runtime patching — possibly simpler than
  the fault-driven path for these specific sites.

## Reproduce

```sh
cd /Users/schmonz/Documents/code/trees/mavericks-claude-ongoing
# (re-fetch 2.1.185 first if the autoupdater reaped it)
# launch a long-lived spin, confirm CPU>70 on the pid in /tmp/spin.pid, then:
sudo dtrace -q -s /tmp/siaddr.d  <PID>   # faulting AVX2 addresses (si_addr)
sudo dtrace -q -s /tmp/paths.d   <PID>   # which emulation path is hot
vmmap <PID>                              # classify each address
```
(`/tmp/siaddr.d`, `/tmp/paths.d`, `/tmp/spin_hold.py` are the throwaway probes
used here; their bodies are inlined above.)
