# avxemu AVX2 binary-translation JIT — Design

**Status:** approved design (brainstorm complete); implementation plan to follow.
**Supersedes** the per-offset shim approach (old Track C) as the *primary* fix. Old
Track C/D in `docs/superpowers/plans/2026-06-28-avxemu-startup-spin-fix.md` is demoted:
Track C becomes, at most, a diagnostic; this spec is the realization of Track D, scoped.

**Required reading first:** `docs/STARTUP-HANG-OPTIONS.md` (the brief) and
`docs/RULED-OUT.md`. This spec assumes their settled facts and does not re-derive them.

---

## 1. Goal & success criteria

Make trusted-project startup of the **latest** upstream Claude Code on the no-AVX2 Mac
(Ivy Bridge / OS X 10.9.5, via the Mavericks launcher + `libavxemu`) match **2.1.179** —
from a multi-minute 100%-CPU spin-and-unusable to a few seconds and responsive — by
**eliminating the per-instruction SIGILL trap on the hot AVX2 path**, generically enough
to keep working as upstream's binary changes.

This is deliberately *not* the per-offset whack-a-mole of patching one named routine
(that rots every release). The win is a translator that accelerates **any** emulated
AVX2, wherever upstream puts it next.

**Gates (evidence before claims — bimodal/noisy system, repeat ≥3×):**
- **Correctness:** the existing differential oracle (`build.sh` on the Haswell box)
  stays at **0 failures, bit-exact**, for every lowering rule and the full suite.
- **Performance:** pyte CPU A/B (`scripts/pyte_watch.py`, ≥3× per version) shows trusted
  startup decay to idle in a few seconds with the JIT on, vs. pegged with it off, and a
  responsive TUI (`pyte_type.py` echo is prompt).

## 2. Why this works — the speedup model

From the live-spin dtrace: `sigreturn` ≈ 52,306 / 3s ≈ **17,400 emulated instr/sec** →
**~57µs per AVX2 instruction**, and the brief is explicit this is *almost entirely the
SIGILL-delivery + sigreturn trap*, not the emulation math.

A typical 90s spin ≈ **1.5M** AVX2 instructions (range ~0.2M–3M across runs). Run those
as native SSE4 in a translated block with no per-instruction trap (Ivy Bridge ~3 GHz;
each 256-bit AVX2 op → 2×128-bit SSE4 + loads/stores; conservatively ~1–5 ns/op →
100–500M/s):

| Path | throughput | 1.5M-instr hot work |
|---|---|---|
| Today (SIGILL trap) | ~17K/s | **~90 s** |
| Existing trampoline (no trap, per-insn C emulation + full ymm spill) | ~1–10M/s | ~0.15–1.5 s |
| **JIT'd native SSE4** | ~100–500M/s | **~3–15 ms** |

So the **spin component** is effectively deleted (3–4 orders of magnitude; we're removing
a ~57µs trap wrapped around a few-nanosecond instruction). **End-to-end startup** is
Amdahl-bounded: the `--debug` log shows ~3.6s of *normal* non-AVX startup work that 179
also does, which the JIT does not touch. Therefore the honest target is **parity with
179 (~a few seconds)** — you cannot beat it, only match it. That is exactly the stated
goal: make the latest run like the non-latest.

## 3. Component model

The JIT is **not a rewrite** — it is a fourth thunk-builder plus a runtime trigger,
reusing the machinery already in `handler.c` / `tramp.c`.

| Existing (keep, reuse) | New (add) |
|---|---|
| `on_sigill` — decode + per-insn emulate | **fault counter** (RIP→count) inside `on_sigill` |
| eager trampoliner (`scan_function` / `gather_run` / `emit_run`) — patches static `__text` runs at load | **fault-driven translator** — same run-gathering, triggered at runtime on hot faulting RIPs |
| `build_thunk_*` + RWX pool (`avxemu_pool_init`, ~96MB near `__text`) + `avxemu_tramp_dispatch` (per-insn C emulation on the side stack) | **`build_thunk_jit`** — emits inline native SSE4 for a run instead of a per-insn C dispatch loop |
| `vec_exec` / `bmi_exec` — proven SSE-only semantics | reused as the **lowering spec + oracle reference** (JIT output must match them bit-for-bit) |
| `run_record` / `tramp_insn` / `decoded` / `decode` / `x86_len` | unchanged; consumed by the JIT codegen |

The pool, the 5-byte-`jmp` patcher, the side-stack discipline, and the
fallback-to-emulation net are all reused.

## 4. Data flow

```
SIGILL
  → decode (existing)
  → increment RIP fault counter
  → below threshold?  → emulate as today (unchanged)
  → just crossed threshold?
        → gather maximal faulting run (existing gather_run logic)
        → emit native SSE4 stub into the RWX cache once
        → patch the faulting site with `jmp stub`
        → resume
  (every later hit runs native, no trap)
```

Anything untranslatable — an op with no lowering rule, an unreachable/unpatchable site —
**silently stays on today's per-instruction emulation path**. Uncovered code is merely
no-faster; nothing regresses. Speedup tracks the covered fraction (the hot loop is, by
definition, the high-payoff fraction; 90% coverage turns ~90s into ~9s).

## 5. The central risk and how staging resolves it

The startup hot code is almost certainly **JSC-runtime-JIT'd** — that is *why* it still
faults despite the eager `__text` pass having already run (it was emitted after the load-
time scan; "JIT frames are anonymous" in the profiling walls corroborates this). Patching
a `jmp` **into volatile JIT'd code** is the one genuinely hard part:

- JSC may overwrite, free, or relocate that code (deopt, GC) under us.
- A cache placed far from the JIT region may be out of `jmp rel32` (±2GB) reach.

This is exactly what the milestone split is organized around.

### Milestone A — per-run native stubs
- **A1 — native codegen for already-patched `__text` thunks.** Upgrade the *existing*,
  load-time-patched runs to emit native SSE4 instead of the per-insn C dispatch. **Zero
  new patching risk** (those sites are already safely patched), pure speedup of any
  static hot runs, and a clean, safe place to **build and oracle the AVX2→SSE4 lowering**.
- **A2 — fault-driven trigger for still-faulting sites.** The runtime trigger from §4,
  which patches volatile sites. Mitigations: a **source-bytes-keyed validity check** so a
  fault at a patched address whose bytes no longer match triggers **invalidate +
  re-translate**; a **far-jump island** when `rel32` won't reach; runaway caps mirroring
  the existing `g_overread_pages` guard. A2 earns the startup win and confronts the
  volatile-code problem at run granularity.

A lands startup at ~179 parity (spin → ~0.15–1.5s per the table) and proves the
codegen + oracle + cache + invalidation machinery.

### Milestone B — whole-loop / trace translation
Translate the entire hot loop — *including the interleaved native instructions* — into
one self-contained native blob the loop branch targets, keeping vector state in registers
across iterations. Execution never re-enters faulting code, so the volatile-patch problem
largely dissolves and the per-iteration register spill vanishes. This is what takes the
spin to **milliseconds** and generalizes to **every** emulation-heavy workload (e.g. the
transcript spin in the record, hot offset `+0x256eaf5`). Continue-to-B is a data-driven
call once A lands; its risk rests on A's proven foundation.

## 6. AVX2 → SSE4 lowering

Each 256-bit VEX op lowers to **2×128-bit SSE4 ops** on the xmm halves; 128-bit VEX ops
map near-1:1 (drop VEX, zero the upper to honor VEX.128 semantics); BMI/LZCNT/TZCNT/MOVBE
lower to SSE4-era scalar sequences. The semantics are **already written and proven** in
`vec_exec` / `bmi_exec` — the JIT emits the native equivalent of what those compute, and
the oracle asserts agreement. New op ⇒ new lowering rule ⇒ new differential test, TDD.

Memory-operand and over-read behavior must preserve the emulator's existing contracts
(the `mem_read` first-page-faults / trailing-page-zero-fill over-read model, segment
overrides, masked moves). Where native codegen can't safely reproduce a contract for a
given op, that op stays on the emulation fallback rather than being lowered.

## 7. Code cache & invalidation

Extend the existing RWX pool model. Entries keyed by `(RIP, source-instruction-bytes)`.
On a fault at a patched site whose bytes no longer match (JSC reused the address),
invalidate and re-translate. Runaway guards cap total translations. Env knobs follow the
existing `AVXEMU_*` convention: `AVXEMU_JIT=0` kill-switch and an A/B toggle for the
performance gate.

## 8. Verification

- **Per lowering rule (TDD):** write the failing differential test first
  (`build.sh <target>`), implement the lowering, confirm green — reusing the oracle.
- **No regressions:** the full differential suite stays 0-failures (on the Haswell box,
  the repo's normal flow).
- **End-to-end:** pyte CPU A/B on trusted 2.1.185, ≥3×, JIT on vs. off; confirm the spin
  decays to idle in a few seconds and the TUI is responsive.

## 9. Deferred to Phase 1 measurement (gates trigger details, not the architecture)

Before A2/B codegen, run the existing `scripts/catch-spin.sh` + `scripts/hot-offset.sh`
(≥3×, demand a stable offset across runs) to answer:
1. Is the hot PC in `__text` or a JIT region?
2. Is it one loop or many blocks?

These set A2's aggressiveness and whether B is needed for *startup* or only for the
general durability win. The architecture above works either way; the measurement only
sets thresholds and priorities.

## 10. Out of scope (YAGNI)

- Repackaging onto a different runtime (clode/Node, own Bun). `clode` remains an
  RE/extraction tool, not a target; repackaging is judged destined to rot.
- Per-named-routine shims as the primary fix (old Track C).
- Any change to upstream app config, plugins, skills, hooks, terminal queries, tmux,
  cpuid dispatch — all ruled out (`docs/RULED-OUT.md`).
