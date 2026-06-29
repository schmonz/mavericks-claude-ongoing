# avxemu Milestone A — Fault-Driven Trampolining Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make trusted-project startup of the latest Claude Code on the no-AVX2 Mac reach 2.1.179 parity (minutes-and-unusable → a few seconds and responsive) by triggering avxemu's *existing* trampoline machinery at runtime on hot faulting instructions, so the startup AVX2 hot path stops paying the per-instruction SIGILL trap.

**Architecture:** The startup spin is the *faulting* path — the `on_sigill` handler emulates one instruction per signal at ~57µs each (dtrace: 52K `sigreturn`/3s). avxemu already has a trap-free path: at load it rewrites runs of faulting `__text` instructions to `jmp` into a thunk that emulates the whole run with no signal (`tramp.c`: `gather_run`/`emit_run`/`avxemu_build_thunk` + the `tt`/`ttg`/`tt2` templates in `tramp.s`). That machinery never fires on the startup hot code because that code is JSC-runtime-JIT'd (emitted *after* the load-time scan) or was skipped. Milestone A adds a **fault counter** in `on_sigill` and, once a RIP is hot, runs the existing run-gather + thunk-build + 5-byte-`jmp` patch **at runtime** on the faulting site. No new instruction-emulation code: it reuses the proven `avxemu_emulate`/`vec_exec` core through the existing dispatch thunk.

**Tech Stack:** C, x86-64, macOS 10.9 (`vm_protect`, `dtrace`, `vmmap`, `otool`), the avxemu differential-test harness (`build.sh`, ground truth on a Haswell box), the repo's Python pyte pty harnesses for the end-to-end startup metric.

---

## Refinement vs. the design spec (read this)

The approved spec (`docs/superpowers/specs/2026-06-28-avxemu-avx2-jit-design.md`) split Milestone A into **A1 (native SSE4 codegen for existing thunks)** + **A2 (fault-driven trigger)**. Reading `tramp.s` showed the existing thunk path already removes the SIGILL trap *without any native codegen* — only per-instruction C emulation remains, which is already ~60–600× faster than the trap. So this plan reorders:

- **Milestone A (this plan):** fault-driven trampolining using the existing dispatch thunk. Hits the startup goal (179 parity) with the least new risk. No native codegen.
- **Milestone B (its own future plan):** native SSE4 codegen + whole-loop/trace translation for the millisecond grade and the general durability win. This absorbs the spec's old "A1."

If Task 7's pyte A/B shows A reaches parity, the startup goal is met and B becomes a pure-performance follow-on. **Action for the executor:** after this plan lands, update the spec's §5 to match this A/B boundary (a one-paragraph edit), so the two docs agree.

---

## GUARDRAILS — read before doing anything

**Read first, in full:** `docs/STARTUP-HANG-OPTIONS.md` (brief), `docs/RULED-OUT.md`, and the spec above. This plan assumes their settled facts and does not re-derive them.

**SETTLED — do NOT re-derive:** it's correct-but-slow emulated AVX2; the trigger is the trust gate (reproduces in an empty trusted dir); 179/untrusted idle, trusted 185/183 spin; the cost is the per-instruction SIGILL trap, not the emulation math.

**Discipline:** this system is **bimodal/noisy** — repeat every CPU/timing measurement **≥3×**, confirm CPU>70% before measuring a spin, never conclude from one run. The goal is the FIX, not re-characterizing the spin.

**Two repos:**
- Plan/docs/tools/measurement: this repo (`mavericks-claude-ongoing`, cwd).
- avxemu source + tests + `build.sh`: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/` (the fix lives here).
- `build.sh` builds the SSE-only core and runs the differential suite; it expects a Haswell+ host for ground truth. The dylib it produces is what the `scripts/claude_185` launcher DYLD-injects.

---

## Repro & measurement primitives (used by several tasks)

- **Trust the test dir** (always back up + restore `~/.claude.json`):
  ```bash
  cp ~/.claude.json /tmp/cj.bak
  python3 - <<'PY'
  import json,os
  p=os.path.expanduser('~/.claude.json'); d=json.load(open(p))
  k="/Users/schmonz/Documents/code/trees/trusttest"
  d.setdefault("projects",{})[k]={"hasTrustDialogAccepted":True}
  json.dump(d,open(p,"w"))
  PY
  # ... run test in that dir ...
  cp /tmp/cj.bak ~/.claude.json   # ALWAYS restore
  ```
- **Harnesses (already on disk in this repo):** `scripts/catch-spin.sh` (catches a confirmed CPU>70% spin, prints `PID` + `TEXT_BASE`), `scripts/hot-offset.sh PID BASE` (dtrace hot-PC → binary offset), `scripts/pyte_watch.py <secs>` (CPU% per 3s; `LAUNCHER=scripts/claude_179|claude_185` selects version), `scripts/pyte_type.py` (writes child pid to `/tmp/spin.pid`, holds it for probing).
- **avxemu env knobs** to use during bring-up: `AVXEMU_DISABLE=1` (opt out entirely), and the new `AVXEMU_JIT=0` (Task 6) to A/B the fault-driven path.

---

## Phase 1 — Measurement & decision gate

> Determines *where* the hot AVX2 is (static `__text` vs JSC JIT region) and whether it's one loop or many — which sets how aggressive the runtime patcher must be (rel32 reach, invalidation pressure). The architecture works either way; this only sets priorities and confirms the trap is the cost.

### Task 1: Capture a stable hot offset (≥3×)

**Files:** none created (uses existing `scripts/catch-spin.sh`, `scripts/hot-offset.sh`).

- [ ] **Step 1: Catch the spin and sample the hot PC, 3×**

Run:
```bash
for n in 1 2 3; do
  eval "$(sh scripts/catch-spin.sh | tail -1)"   # sets PID, CPU, TEXT_BASE
  echo "run $n: PID=$PID CPU=$CPU TEXT_BASE=$TEXT_BASE"
  sh scripts/hot-offset.sh "$PID" "$TEXT_BASE"
  pkill -9 -f versions/2.1.185; sleep 2
done
```
Expected: each run prints `CPU` ≥ 70 and a top `off=0x...`. Record the dominant offset(s).

- [ ] **Step 2: Decide stability**

If the dominant `off=` is the **same across all 3 runs** → it is a stable site; proceed. If offsets differ wildly run-to-run → the hot code is being re-JIT'd at varying addresses (expect this if it's JSC JIT); record that fact (it raises invalidation priority in Task 5) and proceed — fault-driven trampolining keys on the *faulting RIP at runtime*, so it tolerates a moving target.

### Task 2: Classify static `__text` vs JIT region, and record findings

**Files:**
- Create: `docs/hot-routine.md` (in this repo; committed for the next engineer)

- [ ] **Step 1: Check whether the hot PC lands in the binary image**

With a live caught pid (`eval "$(sh scripts/catch-spin.sh | tail -1)"`), run:
```bash
vmmap "$PID" 2>/dev/null | awk '/__TEXT/ {print} /2\.1\.185/ {print}' | head
# Is the hot absolute PC (off + TEXT_BASE) inside a __TEXT mapping of the 2.1.185 image,
# or in an anonymous RWX/JIT mapping far above it?
pkill -9 -f versions/2.1.185
```
Expected: a determination — **(a)** hot PC inside the image `__TEXT` (static, the eager scanner missed it), or **(b)** hot PC in an anonymous executable mapping (JSC JIT). Per the brief's profiling walls (anonymous JIT frames), (b) is expected.

- [ ] **Step 2: Write `docs/hot-routine.md`**

Document: the stable offset(s), the (a)/(b) classification, the mapping addresses, and the implication for Task 5 (if (b): the thunk pool may be out of `jmp rel32` range of the JIT region → far-jump island needed; invalidation likely needed because JSC reuses/frees code). Keep it factual.

- [ ] **Step 3: Commit**

```bash
git add docs/hot-routine.md
git commit -m "docs: locate + classify the startup AVX2 hot site (Phase 1)"
```

---

## Phase 2 — Milestone A: fault-driven trampolining

> All source edits in this phase are in `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/`. The correctness gate for the *emulation* is unchanged (`build.sh` differential suite, already green). The new mechanism (runtime patching) is gated by the existing trampoline tests staying green plus an injection test (Task 3) plus the end-to-end pyte A/B (Task 7).

### Task 3: Expose a runtime "trampoline this address" entry point

The eager installer (`avxemu_install_trampolines`) walks `LC_FUNCTION_STARTS` and calls `scan_function` over the whole image, with `__text` made writable for the pass. We need the *same per-run gather + build + patch* reachable for one address at runtime. Factor the inner mechanism out of `scan_function`/`emit_run` (which already do exactly gather → `build_thunk` → write `jmp rel32`) into a callable that operates on an arbitrary executable address.

**Files:**
- Modify: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/src/tramp.c`
- Modify: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/src/regfile.h` (declare the new entry; it's the existing public header siblings use)
- Test: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/test/tramptest.c` (existing trampoline test — extend it; read it first to match its harness conventions)

- [ ] **Step 1: Read the existing trampoline test harness**

Read `test/tramptest.c`, `test/tramp_harness.s`, and `test/inject.c` to learn how the suite builds a faulting run in memory, installs a thunk, runs it, and checks results. The new runtime entry must be testable the same way. (Do not invent a new harness; reuse this one.)

- [ ] **Step 2: Write the failing test — patch one isolated faulting run at runtime and run it**

In `test/tramptest.c`, add a case mirroring the existing run-thunk test but driving the *new* entry point `avxemu_trampoline_at()` (declared in Step 4) instead of the load-time installer: lay down a small writable+executable buffer containing `[faulting AVX2 run][ret]`, seed input registers, call `avxemu_trampoline_at(buf)`, assert it returns "patched", then execute the buffer and assert the registers/memory match a reference computed by `avxemu_emulate` over the same run. Follow the file's existing assertion/printing style.

- [ ] **Step 3: Run it; verify it FAILS (symbol undefined)**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh 2>&1 | tail -30`
Expected: link/compile failure — `avxemu_trampoline_at` undefined.

- [ ] **Step 4: Implement `avxemu_trampoline_at()` by factoring the existing patch path**

In `tramp.c`, add a runtime entry that reuses the existing static helpers (`gather_run`, `emit_run`, `build_thunk_*`, `run_is_gpr_only`, `run_is_regonly_bmi`) and the existing pool (`avxemu_pool_init` is already called by `avxemu_install_trampolines`; ensure the pool exists — initialize it lazily here if the eager installer didn't run, e.g. on a host where nothing faulted at load):

```c
/* Runtime: trampoline the maximal faulting run starting at `site` (an executable
 * address, in __text OR a JIT mapping). Makes the page writable, gathers the run,
 * builds a thunk, and overwrites `site` with `jmp thunk`. Returns 1 if patched, 0
 * if the run can't be trampolined (the caller then keeps emulating per-instruction).
 * Single concern: one site. No image walking. */
int avxemu_trampoline_at(uint8_t *site) {
    if (!g_pool) {                       /* eager installer may not have run / had nothing to do */
        size_t pool_sz = 96u << 20;
        void *hint = (void *)(((uintptr_t)site + 0x100000) & ~(uintptr_t)0xfff);
        if (!avxemu_pool_init(hint, pool_sz)) return 0;
        if (!g_side_key_ok && pthread_key_create(&g_side_key, 0) == 0) g_side_key_ok = 1;
        detect_features();
    }
    /* gather the maximal faulting run at `site` (no reachability map: a single
     * fault means this IS executing code). insns/offs use addresses, not image
     * offsets, so pass site as both text base and cursor. */
    tramp_insn insns[MAXRUN]; size_t offs[MAXRUN]; int ni = 0;
    size_t p = 0;
    while (ni < MAXRUN) {
        uint8_t *q = site + p;
        int z2, oo; int l2 = x86_len(q, q + 15, &z2, &oo);
        if (l2 <= 0) break;
        decoded d2; int dl2 = decode(q, &d2);
        if (!(dl2 > 0 && d2.op && tramp_faults(&d2))) break;
        offs[ni] = p; insns[ni].addr = (uint64_t)q; insns[ni].dec = d2;
        ni++; p += l2;
    }
    if (ni == 0) return 0;                /* the faulting insn isn't one we trampoline */
    size_t runbytes = p;
    if (runbytes < 5) return 0;          /* no room for a 5-byte jmp at the site */

    uint64_t resume = (uint64_t)(site + runbytes);
    void *thunk = run_is_regonly_bmi(insns, ni) ? build_thunk_bmi(insns, ni, resume)
                : run_is_gpr_only(insns, ni)     ? build_thunk_gpr(insns, ni, resume)
                :                                  avxemu_build_thunk(insns, ni, resume);
    if (!thunk) return 0;

    int64_t rel = (int64_t)((uint8_t *)thunk - (site + 5));
    if (rel < INT32_MIN || rel > INT32_MAX) return 0;   /* out of jmp rel32 reach (see Task 5) */

    /* make the site's page(s) writable, patch jmp rel32, restore exec. */
    uintptr_t lo = (uintptr_t)site & ~(uintptr_t)0xfff;
    uintptr_t hi = ((uintptr_t)site + 5 + 0xfff) & ~(uintptr_t)0xfff;
    mach_port_t task = mach_task_self();
    if (vm_protect(task,(vm_address_t)lo,(vm_size_t)(hi-lo),FALSE,
                   VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY) != KERN_SUCCESS) return 0;
    site[0] = 0xE9; int32_t r32 = (int32_t)rel; memcpy(site + 1, &r32, 4);
    vm_protect(task,(vm_address_t)lo,(vm_size_t)(hi-lo),FALSE,VM_PROT_READ|VM_PROT_EXECUTE);
    return 1;
}
```

Notes for the implementer: `g_pool`, `g_side_key`, `g_side_key_ok`, `gather_run`, `tramp_faults`, `build_thunk_gpr`, `build_thunk_bmi`, `avxemu_build_thunk`, `run_is_gpr_only`, `run_is_regonly_bmi`, `MAXRUN`, `tramp_insn` are all already in `tramp.c` — if any are `static`, they stay `static` (this function lives in the same file). The inline gather above duplicates `gather_run`'s loop deliberately because `gather_run` takes image-relative offsets and a reachability `code` map that don't apply to a single runtime site; if you prefer, generalize `gather_run` instead and call it — either is fine, keep one copy of the logic (DRY).

- [ ] **Step 5: Declare the entry point**

In `regfile.h` (the header siblings already include), add:
```c
/* Runtime trampoline of the faulting run at `site`. Returns 1 if patched. */
int avxemu_trampoline_at(uint8_t *site);
```

- [ ] **Step 6: Run the test; verify it PASSES**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh 2>&1 | tail -30`
Expected: the new `tramptest` case passes; the rest of the suite still reports 0 failures (the `[2] verifying runtime core emits no VEX` gate must still print `clean`).

- [ ] **Step 7: Commit**

```bash
cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu
git add src/tramp.c src/regfile.h test/tramptest.c
git commit -m "feat(avxemu): avxemu_trampoline_at — runtime trampoline of one faulting run"
```

### Task 4: Fault counter + hot trigger in the SIGILL handler

`on_sigill` (in `handler.c`) currently decodes and emulates one instruction per fault. Add a small fixed-size open-addressed RIP→count table; on each emulatable AVX2/BMI fault, bump the count; when it crosses a threshold, call `avxemu_trampoline_at(rip)` once. On success, the site is now a `jmp` and will not fault again; emulate this last instance and return as today.

**Files:**
- Modify: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/src/handler.c`

- [ ] **Step 1: Add the counter table and threshold near the top of `handler.c`**

```c
/* Hot-site fault counter for the fault-driven trampoliner. Fixed open-addressed
 * table; collisions just under-count (worst case: a site trampolines a little
 * later). No locking: a benign race only re-attempts a patch, which is idempotent
 * (a patched site stops faulting). */
#define HOT_SLOTS 4096
#define HOT_THRESHOLD 50          /* faults at one RIP before we trampoline it */
static struct { uint64_t rip; uint32_t n; } g_hot[HOT_SLOTS];

static int hot_bump(uint64_t rip) {     /* returns 1 exactly when count crosses threshold */
    uint32_t i = (uint32_t)((rip * 0x9e3779b97f4a7c15ull) >> 52) & (HOT_SLOTS - 1);
    for (int probe = 0; probe < 8; probe++) {
        uint32_t k = (i + probe) & (HOT_SLOTS - 1);
        if (g_hot[k].rip == rip)      { return ++g_hot[k].n == HOT_THRESHOLD; }
        if (g_hot[k].rip == 0)        { g_hot[k].rip = rip; g_hot[k].n = 1; return HOT_THRESHOLD == 1; }
    }
    return 0;                            /* table region full: never trampolines, just emulates */
}
```

- [ ] **Step 2: Add an env kill-switch flag (read in the constructor)**

At file scope in `handler.c` define `static int g_jit_enabled = 1;`. In `avxemu_install()` (constructor, same file), after the existing env reads, add:
```c
{ const char *j = getenv("AVXEMU_JIT"); if (j) g_jit_enabled = (j[0] != '0'); }
```
(Default on; `AVXEMU_JIT=0` disables the fault-driven path for the A/B in Task 7.)

- [ ] **Step 3: Call the trigger in `on_sigill`, just before emulating**

In `on_sigill`, after a successful `decode(bp, &d)` and before/after the `avxemu_emulate` call, insert the hot-bump + trampoline (use `base`, the real instruction address used for emulation):
```c
if (g_jit_enabled && hot_bump(base)) avxemu_trampoline_at((uint8_t *)base);
```
Place it after the emulation of this instance so this fault still produces correct results even if the patch fails or the run starts mid-stream. (`avxemu_trampoline_at` is declared via `regfile.h`, already included.)

- [ ] **Step 4: Build; full suite green**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh 2>&1 | tail -20`
Expected: builds clean, `[2] ... clean`, suite 0 failures. (Functional behavior on the Haswell test host is unchanged because nothing faults there unless `AVXEMU_FORCETRAMP` is set.)

- [ ] **Step 5: Commit**

```bash
cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu
git add src/handler.c
git commit -m "feat(avxemu): fault-driven hot trigger -> avxemu_trampoline_at"
```

### Task 5: Robustness — invalidation, reach, and caps (driven by Phase 1)

Apply only what Phase 1 (`docs/hot-routine.md`) indicates is needed. If Phase 1 found the hot site is static `__text` with a stable offset, Steps 1–2 may be unnecessary; record that and skip with a note. If it's JSC JIT (expected), do all steps.

**Files:**
- Modify: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/src/tramp.c`
- Modify: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/src/handler.c`

- [ ] **Step 1: rel32 reach — far-jump island (only if the pool can be out of range of the site)**

If `avxemu_trampoline_at` ever returns 0 due to the `rel < INT32_MIN` guard (log this case during bring-up), allocate a small per-site island within ±2GB of the site (an `mmap` near `site` of a 14-byte `jmp [rip+0]; .quad thunk` absolute jump) and point the site's `jmp rel32` at the island. Add an island allocator mirroring `avxemu_pool_init`'s near-hint mmap. Verify with the existing `tramptest` extended to place the thunk pool deliberately far from the test buffer.

- [ ] **Step 2: Invalidation — re-fault on a stale site**

JSC may free/reuse a patched address. If a fault arrives at a RIP we previously patched (the bytes are no longer our `jmp`, or are our `jmp` but the gathered run's source bytes changed), reset its `g_hot` slot so it can be re-evaluated, and do NOT blindly re-patch the same bytes. Key the decision on the first instruction's bytes: store the run's leading bytes in the `g_hot` slot at patch time; on a later fault at that RIP whose bytes differ, treat it as a fresh site. Add the few bytes to the `g_hot` struct and the compare in `hot_bump`.

- [ ] **Step 3: Runaway cap**

Add a global counter of successful runtime patches with a cap (e.g. `200000`, mirroring `g_overread_pages`); above it, stop trampolining (pure emulation fallback) to bound pathological churn. Log once when the cap trips.

- [ ] **Step 4: Build; full suite green; commit**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh 2>&1 | tail -20`
Expected: 0 failures, core still VEX-clean.
```bash
git add src/tramp.c src/handler.c
git commit -m "feat(avxemu): runtime patch robustness (reach island, invalidation, cap)"
```

### Task 6: Produce the dylib and point the launcher at it

**Files:** none in-repo; produces the shippable dylib.

- [ ] **Step 1: Build the installable dylib**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh 2>&1 | tail -5; ls -la /tmp/avxemu/libavxemu.dylib`
Expected: `/tmp/avxemu/libavxemu.dylib` exists and is newer than the source edits.

- [ ] **Step 2: Confirm the launcher injects this dylib**

Inspect `scripts/claude_185` (this repo) to confirm which `libavxemu.dylib` path it `DYLD`-injects, and ensure it points at the freshly built one (copy `/tmp/avxemu/libavxemu.dylib` to that path if needed). Do not change app config — only the dylib.

---

## Phase 3 — End-to-end verification (the real success metric)

### Task 7: pyte A/B — trusted startup, JIT on vs off, ≥3× each

**Files:**
- Modify (record results): `docs/RULED-OUT.md`, `docs/STARTUP-HANG-OPTIONS.md`, and the spec (per the refinement note).

- [ ] **Step 1: Baseline the spin with the new dylib but JIT OFF (control), 3×**

```bash
cp ~/.claude.json /tmp/cj.bak
# (trust the test dir per the primitives block, then:)
cd /Users/schmonz/Documents/code/trees/trusttest
for n in 1 2 3; do AVXEMU_JIT=0 LAUNCHER=scripts/claude_185 \
  python3 /Users/schmonz/Documents/code/trees/mavericks-claude-ongoing/scripts/pyte_watch.py 60 \
  | awk '/^ *[0-9]+ /{print $2}'; echo "--- off run $n ---"; done
cp /tmp/cj.bak ~/.claude.json
```
Expected: CPU pegs ~100% for the usual minutes-long spin (control reproduces the bug).

- [ ] **Step 2: Same, JIT ON (default), 3×**

Repeat Step 1 without `AVXEMU_JIT=0`.
Expected: CPU decays to idle within a few seconds, matching the 179 profile (run `LAUNCHER=scripts/claude_179 pyte_watch.py 60` once as the parity reference). Confirm the spin no longer dominates.

- [ ] **Step 3: Confirm interactivity**

With JIT on, in the trusted dir, run `scripts/pyte_type.py`, type, and confirm prompt echo is prompt (not the starved, barely-echoing TUI). Restore `~/.claude.json`.

- [ ] **Step 4: If JIT ON still pegs — diagnose, don't thrash**

If still slow with JIT on, the likely causes (in order): (a) the hot run is a tight loop re-entering the thunk millions of times, so the per-entry full-`ymm` spill (32 `vmovdqu`, `tramp.s` `tt` template) now dominates — this is the signal that Milestone **B** (native codegen / keep-state-in-registers / whole-loop) is required for parity, *not* a bug in A; (b) `avxemu_trampoline_at` is returning 0 at the hot site (log it — reach or unhandled op); (c) the site is being invalidated every iteration (JSC rewriting it). Record which, with evidence (re-run `hot-offset.sh` with JIT on to see if the `sigreturn` storm is gone but a new hot frame — the thunk spill — appears). This finding is the entry criterion for the Milestone B plan.

- [ ] **Step 5: Record the outcome and reconcile the spec**

Update `docs/RULED-OUT.md` and `docs/STARTUP-HANG-OPTIONS.md` with the before/after CPU and the mechanism, and edit the spec's §5 A/B boundary to match this plan (per the refinement note). Commit in this repo:
```bash
git add docs/RULED-OUT.md docs/STARTUP-HANG-OPTIONS.md docs/superpowers/specs/2026-06-28-avxemu-avx2-jit-design.md
git commit -m "docs: fault-driven trampolining result; reconcile spec A/B boundary"
```

---

## Self-review notes (for the executor)

- **The one real unknown is Task 7 Step 4:** whether the existing per-instruction-dispatch thunk is fast enough at the hot site, or whether the per-entry spill forces Milestone B. The plan is structured so that answer falls out of the A/B measurement rather than a guess.
- **No new emulation code.** Correctness rides entirely on the already-green differential suite (`build.sh`) — Task 3/4/5 only move *when/where* the existing emulation runs. Keep the `[2] core is VEX-clean` gate green at every build.
- **Reuse over re-implement (DRY):** Task 3 deliberately reuses `build_thunk_*`/pool/`tramp_faults`; if you find yourself copying more than the gather loop, generalize the existing `gather_run`/`emit_run` instead.
- **Restore `~/.claude.json` after every trusted-dir run.** Repeat every CPU measurement ≥3×.
```
