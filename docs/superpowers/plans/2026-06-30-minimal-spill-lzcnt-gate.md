# Minimal-Spill lzcnt — Phase 1a (the hypothesis gate) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a **minimal-spill, live-register** native thunk for `lzcnt` (saves only the
~2 scratch GPRs its lowering borrows + preserves undefined flags, instead of the full 16-GPR
`tt2` spill) and run the trusted long-window A/B **gate**: does it remove ~half the no-AVX2
startup spin? Confirm/refute the leading hypothesis (per-op spill overhead, not math) before
building any more ops.

**Architecture:** Today a faulting `lzcnt` jmps to the `tt2` template (spill all 16 GPR +
flags) → an emitted block that reads/writes regfile slots → reload all. This plan adds a
*fully-emitted per-op thunk* that operates on the **live** program registers in place: save
only the 2 scratch GPRs the lzcnt math borrows (push/pop, red-zone-safe), compute
`lzcnt` via `bsr`+fixup on the live src→dst, set CF/ZF/SF/OF via `pushfq`/`popfq`+masked
patch (preserving PF/AF), restore scratch, `jmp` resume. Gated by `AVXEMU_MINSPILL` for A/B.

**Tech Stack:** C + emitted x86-64 machine code (reusing the `nb_*`/`gb_*` byte-emit helpers
in `src/tramp.c`), the avxemu differential oracle (`bmi_exec`), an asm test harness modeled
on `test/tramp_harness.s`, the repo's pyte pty harnesses + the hardened trusted A/B protocol.

---

## GUARDRAILS — read before doing anything

**Read first:** `docs/superpowers/specs/2026-06-30-minimal-spill-per-op-handling-design.md`
and `docs/RULED-OUT.md` ("★ LEADING HYPOTHESIS" + the 2026-06-30 entries).

**Settled:** the spin is pure compute; emulation MATH is ~0 of the lever (native-ON ≈
native-OFF); AVX2 hw (taavibookair) runs .185 fine; the cost is hypothesized to be the per-op
spill frame. This plan tests that with lzcnt (≈46.8% of emulated ops).

**Correctness floor:** the minimal thunk must (a) produce bit-exact `lzcnt` results+flags vs
`bmi_exec`, (b) restore every scratch GPR it borrows, (c) leave all non-destination program
GPRs and PF/AF unchanged. Any uncertainty → the existing full-spill path remains the fallback.

**Repo/host:** avxemu at `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/`,
branch `fix/avxemu-on-upstream`. Host is no-AVX2/no-BMI Ivy Bridge — do NOT run full `build.sh`
(its `-mavx2/-mbmi` oracle #UDs/hangs); build the SSE-only core + run the unit tests like
build.sh's `[6x]` steps. The full silicon suite runs on **taavibookair** before shipping.
Preserve the uncommitted `tramp.c` `AVXEMU_FULLTHUNK` WIP.

**Test-safety (caused false positives before — non-negotiable):** verify trust intact before
EVERY launch; long-window time-to-idle (NOT 60s); isolated dylib (`/tmp/avxemu_*`) +
`scripts/claude_185_natslice` + `AVXEMU_TEST_DYLIB`; NEVER `cp`-over `$MF/libavxemu.dylib`
(crashes the user's running sessions — build to /tmp only); NEVER broad-`pkill` (kill only the
exact spawned child PID); ≥3× per condition.

## Reference: the existing slot-based lzcnt math (reuse, retarget to live regs)

`gb_emit_lzcnt` in `src/tramp.c` already encodes the correct lowering against regfile slots:
capture `CF=(src==0)` via `test;setz` BEFORE `bsr` (dst==src safety), `bsr`→idx,
`opsize-1-idx`, `cmovz`→opsize on zero input, ZF from result, flag mask
`CLR=0xFFFFF73E` = `~(CF|ZF|SF|OF)` (preserves PF/AF), SF=OF=0. Operands there are
`[rsi+RF_GPR_OFF+reg*8]` / `[rsi+RF_FLAGS_OFF]`. This plan keeps the math, changes operands to
**live registers** and flags to **`pushfq`/`popfq`**.

---

## Task 1: Live-register thunk test harness

A minimal thunk is reached via a `jmp` from the patched site and ends with `jmp resume`,
operating on whatever registers are live. To unit-test it we need a harness that loads a
chosen live-register/flags state, enters the thunk, and captures the resulting live state.

**Files:**
- Create: `test/minspill_harness.s`
- Create: `test/minspilltest.c`
- Modify: `build.sh` (add a `[6h]` step compiling+running minspilltest with the SSE-only core)

- [ ] **Step 1: Read the existing harness pattern**

Read `test/tramp_harness.s` and `test/tramptest.c` to match conventions (how they set up
registers, call into emitted thunk code, and read results back; how build.sh links them).

- [ ] **Step 2: Write the harness asm (`test/minspill_harness.s`)**

Implement `void avxemu_minspill_run(const uint64_t in_gpr[16], uint64_t in_rflags, void *thunk_entry, uint64_t resume_marker, uint64_t out_gpr[16], uint64_t *out_rflags)`:
load all 16 GPRs from `in_gpr` and rflags from `in_rflags`, then `jmp thunk_entry` (the thunk
will `jmp` to its baked-in resume address — supply a resume label INSIDE the harness, see
Step 3), and at the resume label store all 16 live GPRs to `out_gpr` and `pushfq`/pop to
`*out_rflags`. Preserve the C-ABI callee-saved registers around the whole thing (save them
before loading the test state, restore after capturing). Keep rsp valid throughout (the thunk
uses push/pop + the red zone).

- [ ] **Step 3: Write the harness driver (`test/minspilltest.c`) with a NO-OP thunk first**

Add a helper that emits a trivial thunk into an RWX buffer: just `jmp resume` (a 5-byte
`E9 rel32` to the resume marker address passed in). Drive it through `avxemu_minspill_run`
with a known input state and assert **out == in** for all GPRs and rflags. This validates the
harness plumbing (state load, resume, capture) independent of any lowering. Wire `[6h]` into
build.sh to compile (`$CORE`) + link (`$PURE $ASM`) + run it.

- [ ] **Step 4: Build + run; verify the no-op harness test PASSES, core VEX-clean**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh 2>&1 | sed -n '/\[2\]/,/\[6h\]/p'` then run the `[6h]` binary directly if build.sh stops at the AVX2 oracle. Expected: `[2]` prints `clean`; minspilltest no-op case `ok`.

- [ ] **Step 5: Commit**

```bash
cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu
git add test/minspill_harness.s test/minspilltest.c build.sh
git commit -m "test(avxemu): live-register minimal-spill thunk harness (no-op validation)"
```

## Task 2: Minimal-spill live-register lzcnt emitter

**Files:**
- Modify: `src/tramp.c` (add `emit_minspill_lzcnt` + scratch-selection helper)
- Modify: `test/minspilltest.c` (lzcnt differential cases)

- [ ] **Step 1: Write the failing differential test (lzcnt via the harness)**

In `minspilltest.c`, for `lzcnt dst,src` over: opsize 32 and 64; `dst != src` and `dst == src`;
src ∈ {0, 1, all-ones, 0x80000000/0x80..00, a few random}; input rflags seeded with PF|AF set
AND the owned bits (CF/ZF/SF/OF) set to garbage; and a couple of distinct `(dst,src)` GPR
pairs (incl. high regs r8–r15): emit the lzcnt minimal thunk (entry from Step 2 of this task,
not yet implemented), run via `avxemu_minspill_run`, and assert:
  - `out_gpr[dst]` == `bmi_exec` lzcnt result (opsize-masked),
  - owned flags CF/ZF/SF/OF == `bmi_exec`,
  - **PF and AF unchanged** from input,
  - **every GPR except `dst`** unchanged from input (proves scratch was restored and nothing
    else was clobbered),
  - rsp unchanged.
Compute the reference with `bmi_exec(BMI_LZCNT, opsize, src, 0, &res, &dummy, &flags)`.

- [ ] **Step 2: Run it; verify FAIL (emitter undefined)**

Run the `[6h]` build/run. Expected: link error / undefined `emit_minspill_lzcnt`, or the
lzcnt cases fail.

- [ ] **Step 3: Implement `emit_minspill_lzcnt(uint8_t **p, const decoded *d, uint64_t resume)`**

Emit, reusing the `nb_*`/`gb_*` byte helpers (raw bytes; no BMI/LZCNT in emitted code):
1. **Pick 2 scratch GPRs** `T1,T2` ∉ {`d->dst`, `d->a_src`, RSP(4)} — e.g. iterate reg ids
   0..15 skipping those three, take the first two. (Document the selection; it must be
   deterministic and never alias dst/src/rsp.)
2. **Save scratch (minimal):** `push T1`; `push T2`. (rsp moves by 16; the lowering uses no
   stack slots beyond pushfq below, so the red zone is respected.)
3. **Capture CF=(src==0) BEFORE bsr** (dst==src safe — src read before any write to dst):
   `xor T1,T1`; `test src,src` (opsize `w`); `setz T1b`.
4. **Compute result into dst:** `bsr dst, src` (w); `mov T2, opsize-1`; `sub T2, dst` (w);
   `test T1,T1`; `mov dst_imm = opsize` then `cmovz dst, <opsize const reg>` — concretely:
   load `opsize` into a register and `cmovz dst, that` when src==0. (Mirror gb_emit_lzcnt's
   structure: it uses `mov $opsize`/`cmovz`; reproduce with live dst + scratch.) For opsize
   32, all ops use 32-bit forms so dst zero-extends to 64.
5. **Set owned flags, preserve PF/AF (live flags via pushfq/popfq):**
   `pushfq`; build the owned-bits value in `T2` (CF from T1 → bit0; ZF=(dst==0) via
   `test dst,dst;setz` → bit6; SF=0; OF=0) exactly as gb_emit_lzcnt builds it; then
   `and qword [rsp], 0xFFFFF73E` (clears CF/ZF/SF/OF, keeps PF/AF + the rest);
   `or qword [rsp], T2`; `popfq`. (The `and/or [rsp],imm/reg` operate on the saved flags
   image; `popfq` makes them live. NOTE order: do this AFTER the `bsr`/`cmov` arithmetic so
   their incidental flag effects are overwritten.)
6. **Restore scratch:** `pop T2`; `pop T1`.
7. **Resume:** `jmp rel32` to `resume`.
Return 1; if `d->opsize ∉ {32,64}` or `d->a_src`/`d->dst` are OPND_MEM/segment, return 0
(fallback). Add a `minspill_lzcnt_supported(d)` predicate for the wiring task.

Caveat to handle: step 5 uses `[rsp]` after the two `push`es; `pushfq` then makes `[rsp]` the
flags image — keep the offsets straight (after `pushfq`, the flags are at `[rsp]`). Keep T1
(holding CF) live across step 4 — do not let step 4 clobber T1 (it uses dst,src,T2 only).

- [ ] **Step 4: Run the differential test; verify PASS + VEX-clean**

Run the `[6h]` build/run. Expected: all lzcnt cases `ok` (result+owned flags match bmi_exec;
PF/AF preserved; only dst changed; rsp intact); `[2]` core `clean`.

- [ ] **Step 5: Fails-first sanity (mutation)**

Temporarily break one thing (e.g. flip the flag mask to `0xFFFFFFFF` so PF/AF aren't cleared
correctly, or move the CF capture AFTER `bsr` to reintroduce the dst==src bug) and confirm the
test FAILS on exactly the expected cases; revert. (Proves the test has teeth.)

- [ ] **Step 6: Commit**

```bash
git add src/tramp.c test/minspilltest.c
git commit -m "feat(avxemu): minimal-spill live-register lzcnt emitter + differential test"
```

## Task 3: Minimal-spill thunk builder + emit_run wiring + AVXEMU_MINSPILL gate

**Files:**
- Modify: `src/tramp.c` (`build_thunk_minspill`, `emit_run` wiring, env flag)

- [ ] **Step 1: Add the env gate**

In `src/tramp.c` add `static int minspill_enabled(void){ const char *e=getenv("AVXEMU_MINSPILL"); return e && e[0]!='0'; }` (default OFF — opt-in for the A/B; flipped on after the gate confirms).

- [ ] **Step 2: Add `build_thunk_minspill(const tramp_insn *insns, int n, uint64_t resume)`**

For a single-instruction run (`n==1`) whose op is `minspill_lzcnt_supported`: allocate from
the pool (`avxemu_pool_alloc`), call `emit_minspill_lzcnt(&p, &insns[0].dec, resume)`, return
the entry. Else return 0. (Single-op only for now — 78% of runs are single-instruction;
multi-op minimal runs are a later op-set task.)

- [ ] **Step 3: Wire into `emit_run` (highest priority when enabled + safe)**

In `emit_run`, before the existing native/bmi/full selection: if `minspill_enabled()` and
`!g_force_full` and the run is a single supported lzcnt and `avxemu_patch_safe(site,5)`, use
`build_thunk_minspill`. On NULL, fall through to the existing selection (full-spill native /
C dispatch) — no regression. With `AVXEMU_MINSPILL` unset, behavior is byte-identical to today.

- [ ] **Step 4: Build core + run all unit tests; VEX-clean**

Run the SSE-only core build + `[6f]`/`[6g]`/`[6h]` tests (reloctest, nativetest, minspilltest)
the way build.sh runs them (hermetic flags). Expected: all green; `[2]` clean. (`emit_run` is
exercised by the existing tramp/reloc tests; minspill path by minspilltest.)

- [ ] **Step 5: Commit**

```bash
git add src/tramp.c
git commit -m "feat(avxemu): minimal-spill thunk builder + emit_run wiring (AVXEMU_MINSPILL gate)"
```

## Task 4: THE GATE — build isolated dylib + trusted long-window A/B

**Files:** none in avxemu; record results in `docs/RULED-OUT.md`.

- [ ] **Step 1: Build the isolated candidate dylib (touches nothing shared)**

Run `sh /tmp/natslice_build.sh` (rebuilds the SSE-only core incl. the new tramp.c to
`/tmp/avxemu_natslice/libavxemu.dylib`; runs the on-target selftest). Confirm
`$HOME/.local/share/claude-mavericks/libavxemu.dylib` is UNCHANGED (build writes only /tmp).

- [ ] **Step 2: Trusted long-window A/B — minspill ON vs OFF, ≥3× each**

Trust the test dir and VERIFY it (a restore can drop it):
```bash
python3 - <<'PY'
import json,os
p=os.path.expanduser('~/.claude.json'); d=json.load(open(p))
k="/Users/schmonz/Documents/code/trees/trusttest"
d.setdefault("projects",{})[k]={"hasTrustDialogAccepted":True}
json.dump(d,open(p,"w")); print("trusted:", d["projects"][k])
PY
```
From `/Users/schmonz/Documents/code/trees/trusttest`, run `pyte_watch.py 240` (time-to-idle),
≥3× each:
- **OFF/control:** `AVXEMU_MINSPILL=0 AVXEMU_NATIVE=1 AVXEMU_TEST_DYLIB=/tmp/avxemu_natslice/libavxemu.dylib LAUNCHER=.../scripts/claude_185_natslice python3 .../scripts/pyte_watch.py 240`
- **ON/treatment:** same with `AVXEMU_MINSPILL=1`.
Also one `claude_179` reference run. Re-verify trust before each. `pyte_watch` self-kills its
own child (no manual pkill). Record the per-3s CPU series / time-to-idle for each.

- [ ] **Step 3: Apply the GATE decision**

- **CONFIRM** (proceed): minspill-ON removes ~the lzcnt share of the spin (lzcnt ≈46.8% of
  emulated ops → expect a substantial, clearly-measurable reduction in time-to-idle / CPU
  vs OFF; ideally roughly-halved hot-loop duration). ⇒ the per-op-spill hypothesis holds.
- **REFUTE** (stop): ON ≈ OFF (no measurable improvement). ⇒ the spill is NOT the per-op
  cost. STOP — do not build more ops. Re-profile (user-PC + the per-op jmp round-trip share)
  and evaluate Phase 2 (region translation) per the spec's trigger.

- [ ] **Step 4: Confirm correctness on a real workload (only if CONFIRM)**

With minspill ON, also run a real trusted project briefly via `pyte_type.py` and confirm the
TUI renders correctly and input echoes (the live-register thunk runs in the real binary — a
correctness bug would corrupt output, not just timing). The silicon differential suite on
**taavibookair** (`sh build.sh` full) must be green before any ship.

- [ ] **Step 5: Record the gate result**

Append to `docs/RULED-OUT.md` (in the mavericks-claude-ongoing repo): the A/B numbers, the
CONFIRM/REFUTE verdict, and the implication. If CONFIRM: note that Phase 1b (vpbroadcastw)
and 1c (tail ops) + the eventual default-on flip are the next plan. If REFUTE: record that
per-op spill is ruled out as the dominant cost and Phase 2 (region translation) is the path.
```bash
cd /Users/schmonz/Documents/code/trees/mavericks-claude-ongoing
git add docs/RULED-OUT.md
git commit -m "docs: minimal-spill lzcnt gate result (CONFIRM/REFUTE per-op-spill hypothesis)"
```

---

## What this plan deliberately does NOT include (gated on Task 4)

- **Phase 1b/1c** (vpbroadcastw + the BMI/vector tail as minimal-spill live-register
  lowerings, multi-op minimal runs, and flipping `AVXEMU_MINSPILL` default-on): only if Task 4
  CONFIRMS. Each is the same pattern as lzcnt (live-register lowering + minimal save + oracle
  + A/B increment); they get their own plan once the gate is green.
- **Phase 2** (hot-region/loop translation, no per-op round-trip): the spec's planned,
  triggered fallback — built only if minimal-spill is applied to the hot ops and the spin
  persists with the residual shown to be the per-op jmp round-trip. Its own spec/plan when
  triggered. (Recorded here so it is not forgotten.)

## Self-review notes (for the executor)

- The one genuine unknown is Task 4's gate; everything before it is standard emitter work with
  an oracle. Don't flip `AVXEMU_MINSPILL` default-on or build more ops until the gate confirms.
- Correctness rides on: the oracle (result+flags vs bmi_exec), the "only dst changed / scratch
  restored / PF/AF preserved / rsp intact" assertions (these prove minimal-spill safety), and
  the fails-first mutation. Keep the adversarial review for the emitter (machine code).
- Reuse the `gb_emit_lzcnt` math and `nb_*`/`gb_*` byte helpers — do not re-derive encodings.
- Every launch: verify trust; long window; isolated dylib; never touch `$MF`; never broad-pkill.
