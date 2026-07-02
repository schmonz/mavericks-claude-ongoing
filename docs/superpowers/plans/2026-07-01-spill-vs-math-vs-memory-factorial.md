# Across-the-Board Native Lowering of the Dominant Emulated Ops — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

---
## ⚑ STATUS (2026-07-02, Fable session) — BOTH BLOCKERS FIXED + FAULT STORM KILLED; spin persists (work-volume-bound)

avxemu `fix/avxemu-on-upstream` HEAD=`2e050d5`. The three "NEXT" items from the 2026-07-01 STATUS
below are all DONE. Full narrative: `docs/RULED-OUT.md` TOP section (2026-07-02).

- ✅ **BLOCKER 1 (mulx SIGILL) FIXED** (`b3b61fd`). Root cause: `emit_minspill_mulx` wrote dlo LAST,
  so `mulx rax,rax,rax` dlo==dhi forms (take-the-high-half idiom, 459 static sites) kept the LOW half
  → corrupted JSC → SIGILL in the pool. Fix = write dhi last. Real-decode samples `_mx19..23` added;
  1344 minspilltest cases green; MINSPILL=1 now runs the real binary clean for minutes.
- ✅ **CORRECTNESS GATE PASSED.** `AVXEMU_FORCETRAMP=1 AVXEMU_MINSPILL=1 claude --help` output ==
  MINSPILL=0 on target; oracle-air `oracle`+`bmi_oracle` green (bmi_exec == silicon). oracle-air is macOS 15
  now → reloctest/minspilltest fail there ENVIRONMENTALLY (RWX/dyld-insert blocked; HEAD~3 identical,
  NOT a regression); injection tests only run on the Mavericks target.
- ✅ **FAULT STORM found + 72% killed** (`5da4233`; diagnostics `143b5e4` FAULTHIST, `2e050d5`
  FAULTSNAP). 94% of sustained SIGILLs were 3 static zcnt sites declined by `patch_safe`'s blanket
  has_indirect rule → jump-table-aware resolution relocates them. sigtramp 26%→0%, handler C 16%→0%.

**THE SPIN PERSISTS AND IS NOW CHARACTERIZED (this is the crux):** the app is at its normal REPL
prompt while pegged (NOT startup). FAULTSNAP shows the hot loop scanning Bun BUILTIN JS module source
= JSC lex/atom-hash over the bundled app. Post-fix busy profile: **~87% native pool thunks + ~12%
app**. Per-op lowering is real (~1.3×/op) but total work dominates: 3×3 TTIDLE A/B (300s) = both arms
never idle. **The measurement question flipped:** it's no longer "is the tier correct/does it fire"
(yes) but "can per-op lowering shrink a loop this large, or is the loop condition-bound?"

**NEXT (supersedes Tasks 3–8 below AND the old 2026-07-01 NEXT), in priority:**
1. **Settle work-vs-condition FIRST** (cheap, decisive): the string-address recurrence test at higher
   FAULTSNAP density (`docs/IDEAS.md` top). If the module sweep RE-RUNS the same source addresses →
   condition-bound → NO per-op lowering can end it; pivot to finding why JSC re-links (a JSC/engine
   condition, not an avxemu op). If each address is touched a bounded number of times → work-bound →
   proceed to (2).
2. **Lower mem-source `bzhi` + vector group-scan** — the 87%. `minspill_bzhi_supported` DECLINES all
   memory operands (`a_src==OPND_MEM` etc.), so the hot Swiss-table probes still take full-spill
   thunks. The hot forms are simple `[base+disp]` loads (NOT rip-relative: hotmem.c scan = rip-rel 14
   vs base-only 2487), so a mem-source minspill variant is tractable. TDD via a new minspilltest
   mem-operand case + real-decode samples; gate on FORCETRAMP output==native.
3. **Fn-B jump-table resolution** (`+0x2f1caa0`, 18.5KB, table base lea'd far from dispatch) — POLISH
   only: removes the last ~1-2% handler overhead (the dominant remaining fault site), not the 87%.

Tasks 3–8 below are the ORIGINAL native-block plan, kept for context, SUPERSEDED.
---

**Goal:** Collapse the no-AVX2 startup spin by extending avxemu's Milestone-B register-resident native codegen from its current 8 vector ops to the **entire dominant op tier** (BMI2 scalar `mulx/shlx/shrx/bzhi/tzcnt/blsr/andn/rorx` ≈ 90% of emulated ops, plus the vector group-scan ops), so the load-time relocator lowers each static `__TEXT` site to native SSE/scalar **instead of** a full-spill trampoline → C-emulate round-trip.

**Architecture:** This is HEROIC-OPTIONS **Tier 1b** ("eliminate the AVX2 by rewriting static `__TEXT` to native"), realized through avxemu's existing relocation + native-codegen infrastructure rather than a separate Mach-O patcher (SSE replacements are longer than the BMI2 originals, so in-place byte patching is infeasible; relocation to a pool is the right mechanism, and avxemu already does it). P0 (below) established the dominant ops are **register-only BMI2 in static `__TEXT`, trampoline-dominated** — not volatile JIT — so this is static, correctness-oracle-gated work with no live-code hazard. We go **across the board** (whole tier at once), NOT one instruction at a time (minspill's incremental approach is superseded).

**Tech Stack:** C11 SSE4.2-only core + x86-64 asm emitters (`$AV/src/tramp.c` native emitter, `src/reloc.c` lowering table), avxemu differential oracle (`test/oracle.c`, `test/bmi_oracle.c`) which must run on a **Haswell+ host** for ground truth, the pyte harnesses, `sample`/`lldb`.

**Key paths / facts:**
- avxemu source: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu` (`$AV`)
- native-codegen gate: `AVXEMU_NATIVE` (`tramp.c:534`, default ON, `=0` disables); currently 8 vector ops only.
- minspill pattern to reuse: `emit_minspill_op` + `gb_*`/`nb_*` byte helpers + red-zone/flag discipline (`tramp.c`, `test/minspilltest.c`).
- reloc lowering hook: `reloc.c:470` ("prefer an inline native lowering for the faulting op").
- isolated test dylib the launcher injects: `/tmp/avxemu_natslice/libavxemu.dylib` (built Task 0).
- Haswell correctness host: **oracle-air** (AVX2) — the ONLY place the differential oracle's ground truth is valid; the no-AVX2 target can only run the SSE-only `AVXEMU_SELFTEST` subset.
- harness repo (cwd): `/Users/schmonz/Documents/code/trees/mavericks-claude-ongoing` (`$MC`); repro project `$D=/Users/schmonz/Documents/code/trees/trusttest`.

---

## ⚠️ METHODOLOGY GUARDRAILS — read every task through these (2026-07-01, after killing the user's 179 twice)

See memory `[[no-broad-pkill-claude]]`. NON-NEGOTIABLE:
1. **Kill ONLY the exact PID** from `/tmp/spin.pid`: `P=$(cat /tmp/spin.pid); kill -9 "$P"`. **NEVER** `ps | grep <version> | … kill`, **NEVER** `pkill -f`, and **NEVER** put `179` in any pattern — the user's live daily session is **2.1.179**. Inventory read-only is fine; piping a version-grep into kill is the forbidden broad kill.
2. **Never touch the shared `~/.claude.json`.** Set trust via a **throwaway `HOME`** (`/tmp/spin_home`) with its own `.claude.json` carrying only `{projects:{<$D>:{hasTrustDialogAccepted:true}}}` + onboarding; the pyte harness inherits `HOME`. (Logged-out is fine — auth does not affect the spin.)
3. **Never `cp` over `$MF/libavxemu.dylib`** (running sessions mmap it → SIGBUS). Build only to `/tmp/avxemu_natslice/…` and inject via `AVXEMU_TEST_DYLIB`.
4. Bimodal system → repeat every live measurement **≥3×**, report all. Verify the spin actually pegs (control must peg for a valid A/B).

### Throwaway-HOME trust helper (used by all live tasks)

```bash
setup_spin_home() {   # creates /tmp/spin_home with trust for $D, no touch to ~/.claude.json
  D=/Users/schmonz/Documents/code/trees/trusttest
  mkdir -p /tmp/spin_home
  python3 - "$D" > /tmp/spin_home/.claude.json <<'PY'
import json,sys
d={"projects":{sys.argv[1]:{"hasTrustDialogAccepted":True,"projectOnboardingSeenCount":9}},
   "hasCompletedOnboarding":True,"bypassPermissionsModeAccepted":True}
print(json.dumps(d))
PY
}
# launch a spin: HOME=/tmp/spin_home so trust comes from there, NOT ~/.claude.json
```

---

## Task 0: (DONE) Isolated OPHIST/native dylib built

`/tmp/avxemu_natslice/libavxemu.dylib` built 2026-07-01 from current source (SSE-only core, VEX-free, `AVXEMU_SELFTEST` green, has OPHIST). Rebuild recipe if needed (under `sh`, correct word-splitting):

```bash
sh -c 'AV=/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu; OUT=/tmp/avxemu_natslice
CORE="-O2 -Wall -std=c11 -msse4.2 -mno-avx -mno-fma -I$AV/src"; PURE=""
for f in exec exec_bmi softfma names decode lde patch_mem tramp reloc handler; do clang $CORE -c "$AV/src/$f.c" -o "$OUT/$f.o"; PURE="$PURE $OUT/$f.o"; done
clang $CORE -c "$AV/src/selftest.c" -o "$OUT/selftest_c.o"; clang -c "$AV/src/selftest.s" -o "$OUT/selftest.o"; clang -c "$AV/src/tramp.s" -o "$OUT/tramp_s.o"
clang -dynamiclib -O2 -msse4.2 -mno-avx -mno-fma -install_name "$HOME/.local/share/claude-mavericks/libavxemu.dylib" $PURE "$OUT/selftest.o" "$OUT/selftest_c.o" "$OUT/tramp_s.o" -o "$OUT/libavxemu.dylib"'
```

---

## Task 1: (DONE) P0 — dominant op-mix, operand form, static-vs-JIT, fault/tramp

Recorded in RULED-OUT (attribution-correction + this section). Findings that route the build:
- **Op-mix (OPHIST, 11.68M ops/12s):** mulx 35% · shlx 23% · bzhi 12% · tzcnt 9% · blsr 4% · andn 4% · shrx 4% (**BMI2 tier ≈ 90%**); vector group-scan (`vpbroadcastq/vpcmpeqb/vpmovmskb/vpsubb/…`) ≈ 10%.
- **Operand form:** dominant `mulx` is **register-only** (`mulxq %r9,%r8,%rdx`, `mulxq %rcx,%rdx,%rcx`) in static `__TEXT` hot string fns → register-residency applies.
- **Fault/tramp:** trampoline-dominated (`tramp_dispatch` ≫ `run_on_stack`) → static sites, load-scanned.
- **Signature:** Swiss-table/SIMD hash-map (mulx hasher + `vpcmpeqb→vpmovmskb→tzcnt→blsr` group scan).

---

## Task 2: Confirm where the ~10% VECTOR group-scan ops live (static `__TEXT` vs JIT-emitted)

Decides whether we are 100%-Tier-1b or 90/10 Tier-1b/2a. One spin, isolated HOME, exact-PID.

**Files:** use `$MC/scripts/claude_185_natslice`, `pyte_hold.py`, `lldb`.

- [ ] **Step 1: Launch a trusted spin under the OPHIST dylib (throwaway HOME)**

```bash
cd /Users/schmonz/Documents/code/trees/mavericks-claude-ongoing; SCR=$PWD/scripts
setup_spin_home    # defined above
rm -f /tmp/spin.pid
( cd "$D" && HOME=/tmp/spin_home AVXEMU_OPHIST=1 AVXEMU_TEST_DYLIB=/tmp/avxemu_natslice/libavxemu.dylib \
   LAUNCHER="$SCR/claude_185_natslice" HOLD_SECS=90 python3 "$SCR/pyte_hold.py" >/tmp/hold_t2.out 2>&1 & )
```
Wait for peg (until-loop on `ps -o %cpu=`); do NOT touch `~/.claude.json`.

- [ ] **Step 2: For each hot vector op, find a faulting site and check if its address is static `__TEXT` or JIT**

```bash
PID=$(cat /tmp/spin.pid)
lldb 2>/dev/null <<EOF > /tmp/t2_bt.txt
process attach --pid $PID
thread backtrace
detach
quit
EOF
# static __TEXT is 0x1..(base)+offset within the 2.1.185 image; JIT is <unknown binary> / anon RWX.
grep -E 'frame #' /tmp/t2_bt.txt | grep -E '2\.1\.185|unknown'
```
Then disassemble one hot string fn (as in P0) and grep for `vpcmpeqb|vpmovmskb|vpbroadcast`: if they appear in the **on-disk** static binary at that offset → static; if the vector ops only appear in `<unknown binary>` JIT frames → JIT-emitted.

- [ ] **Step 3: Teardown (exact PID only) + record**

```bash
P=$(cat /tmp/spin.pid); kill -9 "$P"
```
Record in RULED-OUT: vector ops static or JIT. **Branch:** if static → include them in Task 6; if JIT → note Task 6 covers BMI (90%) and the vector 10% is deferred to a future Tier-2a emit-time hook (BMI alone may already collapse the spin — measure in Task 7 before building 2a).

---

## Task 3: Build the BMI differential-oracle harness for the full tier (ground truth on Haswell)

Extend `test/bmi_oracle.c` to cover every op in the tier with random inputs, comparing the native-lowered result to `bmi_exec` (the reference) — including **flags** for ops that the BMI2 form leaves undefined/unchanged (this is the correctness trap: legacy replacements like `mul`/`shl` set flags that `mulx`/`shlx` do NOT).

**Files:** Modify `$AV/test/bmi_oracle.c`; run on **oracle-air (Haswell)**.

- [ ] **Step 1: Add per-op random differential cases for `mulx, shlx, shrx, sarx, bzhi, tzcnt, blsr, blsi, blsmsk, andn, rorx`**

For each: generate N=100k random operand sets (incl. edge values 0/‑1/1<<63), run `bmi_exec` reference, assert the *candidate native lowering* (Task 5/6, behind `AVXEMU_NATIVE`) is byte-identical in destination(s) AND that the flags match the **BMI2 semantics** (e.g. `mulx` touches no flags; `shlx/shrx/sarx` touch no flags; `bzhi/blsr/blsi/blsmsk/andn` set ZF/SF/CF per spec; `tzcnt/lzcnt` set ZF/CF; `rorx` no flags).

- [ ] **Step 2: Run the oracle on the Haswell host (baseline: all currently-emulated, must PASS)**

```bash
# on oracle-air:
cd <avxemu>; clang -O2 -std=c11 -mavx2 -mfma -mbmi -mbmi2 -mlzcnt -Isrc \
  test/bmi_oracle.c src-obj/exec_bmi.o src-obj/names.o -o /tmp/bmi_oracle && /tmp/bmi_oracle
```
Expected: PASS for the reference path (proves the harness + expected-flags table are correct before we add lowerings).

- [ ] **Step 3: Commit the extended oracle**

```bash
cd <avxemu>; git add test/bmi_oracle.c && git commit -m "test: full BMI2-tier differential oracle incl. flag semantics"
```

---

## Task 4: Wire native-lowering dispatch for the BMI tier into the trampoline/relocator

Add the dispatch so the load-time relocator emits a register-resident native block for each tier op behind `AVXEMU_NATIVE`, falling back to the existing spill-thunk→C-emulate when a lowering is absent (so partial rollout stays correct).

**Files:** Modify `$AV/src/tramp.c` (native emitter dispatch, near `g_native`/`emit_minspill_op`), `$AV/src/reloc.c` (`:470` lowering hook).

- [ ] **Step 1: Add an `emit_native_bmi(op, decoded*, uint8_t** p)` dispatch returning 0 when unhandled**

Model on `emit_minspill_op`: reuse `gb_*`/`nb_*` byte helpers, red-zone discipline, and the live-register spill-avoidance. Route from the reloc lowering hook and the trampoline builder; when it returns 0, keep current behavior (no regression).

- [ ] **Step 2: Build + selftest on the target (SSE-only path still valid)**

```bash
# Task 0 rebuild recipe → /tmp/avxemu_natslice/libavxemu.dylib
AVXEMU_SELFTEST=1 DYLD_INSERT_LIBRARIES=/tmp/avxemu_natslice/libavxemu.dylib /usr/bin/true && echo "selftest OK"
```
Expected: `selftest OK` (dispatch present, no op lowered yet → all fall through, still correct).

---

## Task 5: Native lowering — the two biggest ops first (`mulx` 35%, `shlx` 23%) — TDD per op

Do the two dominant ops first so Task 7 can measure early whether the approach collapses the spin before building the whole tier.

**Files:** Modify `$AV/src/tramp.c` (`emit_native_bmi`), test via Task 3 oracle on Haswell + selftest on target.

- [ ] **Step 1 (mulx): write the failing oracle case first**, then implement register-resident lowering: `mulx dhi,dlo,src` computes `dhi:dlo = src * rdx` with **no flag change** → emit `mov`s to marshal into rax, `mul`-family that preserves flags via `pushfq/popfq` around it (or `imul`-free widening), write both dests; verify **flags untouched**. Run oracle on Haswell → PASS; selftest on target → PASS.
- [ ] **Step 2 (shlx/shrx/sarx): failing case first**, then lower variable shift **without touching flags** (legacy `shl/shr/sar` set flags → wrap with flag save/restore or use a flag-neutral sequence). Oracle PASS (incl. flags-unchanged) on Haswell; selftest on target.
- [ ] **Step 3: Commit** `feat(avxemu): native register-resident lowering for mulx + shlx/shrx/sarx`.

---

## Task 6: Native lowering — the remainder of the tier (`bzhi, tzcnt, blsr, andn, rorx`, + vector group-scan if Task 2 = static)

Same TDD-per-op loop. For each: failing oracle case (with correct BMI2 flag semantics) → register-resident lowering → oracle PASS on Haswell → selftest PASS on target → commit.

- [ ] **Step 1: `bzhi`** (zero bits from index; sets ZF/SF/CF) — lower to `mov/shl/mask` with correct CF (index>63) + ZF/SF.
- [ ] **Step 2: `tzcnt`** (already have lzcnt→bsr fixup in reloc.c Milestone-A; mirror for tzcnt→bsf + zero-input CF/ZF).
- [ ] **Step 3: `blsr/blsi/blsmsk`** (`x&(x-1)` / `x&-x` / `x^(x-1)`; flags per spec).
- [ ] **Step 4: `andn`** (`~a & b`; sets SF/ZF, clears CF/OF).
- [ ] **Step 5: `rorx`** (rotate, no flags).
- [ ] **Step 6 (only if Task 2 said VECTOR ops are static):** add the vector group-scan ops (`vpcmpeqb/vpmovmskb/vpbroadcastq/vpsubb/…`) to the existing vector native emitter (Milestone-B already lowers 8 vector ops; extend to these), oracle via `test/oracle.c` on Haswell.
- [ ] **Step 7: Commit** each op-group separately.

---

## Task 7: Tier-2 live confirmation — PROXY metric (isolated-HOME burst), then MANDATORY real-context follow-up

**The isolated HOME does NOT reproduce the sustained spin — it does a finite ~15–17M-op burst then
exits cleanly** (see RULED-OUT "REPRO CHARACTERIZATION"). So the live metric is the **burst**:
wall-time + OPHIST op-count to finish startup, isolated HOME, exact-PID, ≥3×. A correct native
lowering should reduce wall-time for the same op-count (ops move from spill-thunk→C-emulate to native).

**⚠️ PROXY CAVEAT (user-mandated 2026-07-01):** the burst is a PROXY. A win on the burst is NOT a
win until **re-confirmed in the ORIGINAL context** — the real-`HOME` sustained spin on a real project.
Task 7 has TWO stages; Stage B is not optional.

### Stage A — PROXY: isolated-HOME burst A/B

- [ ] **Step A1: A/B `AVXEMU_NATIVE=0` (baseline, all emulated) vs `=1` (tier lowered), 3× each.** Launch the isolated-HOME burst (Task 2 Step 1 recipe: throwaway `HOME=/tmp/spin_home`, isolated dylib, `AVXEMU_OPHIST=1`). The process finishes the burst and exits; capture **wall-time to exit** and **OPHIST TOTAL** for each run.
- [ ] **Step A2: Record** the wall-time delta for the same op-count (native should be faster). Teardown exact PID only (`kill -9 $(cat /tmp/spin.pid)`), never a version-grep-kill.
- [ ] **Step A3: Proxy verdict** — did `=1` cut burst wall-time materially vs `=0`? If yes → promising, go to Stage B. If no → the residual (un-lowered ops / vector 10% / memory) dominates; finish the tier or reassess before Stage B.

### Stage B — ORIGINAL CONTEXT (mandatory follow-up; proxy ≠ truth)

- [ ] **Step B1: Re-confirm in the real sustained spin.** The burst is a proxy (RULED-OUT "REPRO CHARACTERIZATION"). Reproduce the real-`HOME` sustained spin (real project / real `~/.claude` data volume) with `=0` vs `=1` and measure whether the sustained spin **actually shrinks / idles** (`scripts/pyte_ttidle.py`). **This must use the safe isolation for teardown but a data-faithful environment** — decide with the user how to get a sustained repro without disrupting their live 179 (e.g. a copied-forward `~/.claude` snapshot into the throwaway HOME until it sustains).
- [ ] **Step B2: Decision**
  - **Sustained spin idles/shrinks under `=1`** → SUCCESS confirmed in real context. Ship (atomic `mv` into `$MF`, guardrail #3, per-version re-apply).
  - **Proxy improved but sustained did NOT** → the sustained spin's extra work is elsewhere (data-scaled path not covered by the tier) → back to investigation with that specific gap.

---

## Task 8: Record outcome durably

- [ ] Update `$MC/docs/RULED-OUT.md` + `[[start-here]]`: whether across-the-board native lowering collapsed the spin, the measured deltas, and (if shipping) the per-version re-apply procedure. Reconcile explicitly against the minspill REFUTE (coverage-gap now closed by covering the DOMINANT ops), the 0.007% misattribution, and the 1.3.14→1.4.0 boundary.
- [ ] Commit docs.

---

## Self-review notes

- **Coverage:** ruled-outs (config/upstream/old-version) → HEROIC Tier-1b chosen → P0 done → confirm vector static/JIT (T2) → oracle harness (T3) → dispatch (T4) → lower dominant 2 (T5) → lower rest (T6) → live confirm/idle (T7) → record (T8).
- **Correctness-first:** every op is TDD'd against the differential oracle on a **Haswell host** BEFORE it can affect the spin; target only runs the SSE selftest subset. Timing is never trusted before correctness.
- **Early exit:** T5+T7 measure after just the two biggest ops (58%) — if that already idles, the rest of T6 is optional.
- **Guardrails:** every live task uses throwaway `HOME` + exact-PID kill; no version-grep-kill; no `~/.claude.json` writes; no live `$MF` overwrite.
- **Superseded:** the earlier spill-vs-math-vs-memory micro-attribution (old Tier 1) is dropped — P0's register-only/static findings justify going straight to native-inline, which removes spill+math+round-trip together.
- **Open risk:** BMI2 flag semantics are the correctness trap (legacy replacements set flags the BMI2 forms don't); the oracle's expected-flags table (T3) is the guard.
