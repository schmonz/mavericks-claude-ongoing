# avxemu Milestone A — Block-Window Relocation Implementation Plan

> **⚠️ EXECUTED + RULED OUT as the startup fix (2026-06-30).** This plan (Milestone A) and
> Milestone B (native codegen) were implemented, reviewed, and oracle-gated — they correctly
> remove AVX2/BMI emulation overhead. But measurement showed the startup spin is only ~32%
> emulation (Bun's JIT'd app hot loop dominates, pure compute), so they do NOT fix startup.
> Do not resume this as the fix path. See `docs/RULED-OUT.md` (2026-06-30 entries).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Revised 2026-06-29** after Phase-1 measurement + 4-site recon. The earlier version of
> this plan assumed AVX2-vector hot code and reused the existing 5-byte-`jmp` run
> trampoliner — which **cannot** patch the actual hot sites (isolated 4-byte BMI ops). See
> `docs/RULED-OUT.md` (2026-06-29 corrections) and the design spec.

**Goal:** Make trusted-startup of the latest Claude Code reach 2.1.179 parity on the
no-AVX2 Mac by making the residual faulting instructions trap-free via **block-window
relocation** — a general mechanism that handles isolated, sub-5-byte faulting sites the
existing run-trampoliner structurally can't.

**Architecture:** The residual startup spin is isolated scalar BMI ops (`LZCNT`/`TZCNT`,
4 bytes; `SHLX`/`ANDN`, 5 bytes), each `#UD`-ing into ~57µs SIGILL emulation. A 4-byte
faulting instruction has no room for a 5-byte `jmp rel32`, so it can't be trampolined.
`avxemu_relocate_block(site)` fixes this generally: pick a window starting at the faulting
instruction and forward-extending over following instructions until ≥5 bytes; emit a
relocated copy into the RWX code cache (faulting instr → native lowering or an
emulator-call stub; following legal instrs → copied verbatim); append `jmp back`; patch
`jmp rel32` at `site`. Correctness floor: any window the relocator can't safely build →
return 0, stays on SIGILL emulation (no regression). Trigger: fault-driven counter in
`on_sigill`.

**Tech Stack:** C, x86-64, macOS 10.9 (`vm_protect`, `dtrace`, `otool`, `lldb`), the
avxemu differential oracle (`build.sh`, ground truth on a Haswell box), the repo's pyte
pty harnesses for the end-to-end metric.

---

## GUARDRAILS — read before doing anything

**Read first, in full:** `docs/STARTUP-HANG-OPTIONS.md`, `docs/RULED-OUT.md` (esp. the
2026-06-29 premise corrections), `docs/hot-routine.md` (the site recon), and the design
spec `docs/superpowers/specs/2026-06-28-avxemu-avx2-jit-design.md`.

**SETTLED (do NOT re-derive):** trust-gated startup spin; cost is the per-instruction
SIGILL kernel trap (~57µs), not the math; the residual hot sites are **static `__TEXT`,
scalar BMI, isolated/4-byte** (single `__TEXT` segment; not JIT'd; not AVX2-vector); avxemu
already emulates these correctly (`bmi_exec`). The vector ops are already trampolined.

**Discipline:** bimodal/noisy — repeat every CPU/timing measurement **≥3×**, CPU>70%
before measuring. Goal is the FIX. **Correctness first:** the relocator must *abort to the
existing SIGILL-emulation path* for anything it can't provably handle — never emit a guess.

**Repos & build:**
- Plan/docs/measurement: this repo (`mavericks-claude-ongoing`, cwd), branch `main`.
- avxemu source/tests/`build.sh`: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/`, branch `fix/avxemu-on-upstream`. **Preserve the existing uncommitted `tramp.c` `AVXEMU_FULLTHUNK` WIP** (it's intended). `build.sh` builds the SSE-only core, runs the differential suite, and verifies the core emits no VEX (`[2] ... clean`).
- The launcher `scripts/claude_185` (this repo) DYLD-injects the built dylib.
- **The autoupdater reaps old versions**: if `~/.local/share/claude/versions/2.1.185` is missing, `sh scripts/fetch-version.sh 2.1.185` first.

## Repro & measurement primitives

- Trust the test dir (always back up + restore `~/.claude.json`):
  ```bash
  cp ~/.claude.json /tmp/cj.bak
  python3 - <<'PY'
  import json,os
  p=os.path.expanduser('~/.claude.json'); d=json.load(open(p))
  k="/Users/schmonz/Documents/code/trees/trusttest"
  d.setdefault("projects",{})[k]={"hasTrustDialogAccepted":True}
  json.dump(d,open(p,"w"))
  PY
  # ... run ...
  cp /tmp/cj.bak ~/.claude.json
  ```
- `scripts/catch-spin.sh` (catch CPU>70 spin → PID, TEXT_BASE), `scripts/pyte_watch.py <secs>` (CPU% per 3s; `LAUNCHER=` selects version), `scripts/pyte_type.py` (pid → `/tmp/spin.pid`, holds for probing). `AVXEMU_RELOC=0` (added in Task C) is the A/B kill-switch.

## Phase 1 — DONE

Measurement complete (`docs/hot-routine.md`, commit `9c221a5`): 4 stable static-`__TEXT`
BMI sites; root cause = isolated sub-5-byte faulting instructions. Lowering targets:
`LZCNT`, `TZCNT` (4-byte legacy `F3 0F BD/BC`), `SHLX`, `ANDN` (5-byte VEX). One loop site
(`0x379d4a2`); it becomes trap-free once its `tzcnt` is relocated (its `shlx`/`andn` are
≥5 bytes → handled by the existing run-trampoliner).

---

## Phase 2 — the relocation mechanism (avxemu repo)

> All edits in `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/`.
> New mechanism lives in a new file `src/reloc.c` (one clear responsibility: build a
> relocated copy of a window + patch the site), declared in `regfile.h`.

### Task A: relocation skeleton — verbatim copy + emulator-call stub + jmp-back

The correctness-first core: relocate a window whose faulting instruction is handled by the
**existing emulator** (via a per-instruction spill→`avxemu_emulate`→reload stub, exactly
the discipline `tramp.s`/`avxemu_tramp_dispatch` already use) and whose following
instructions are copied verbatim. This eliminates the kernel trap with zero new emulation
logic. Native inlining is Task B.

**Files:**
- Create: `/Users/.../avxemu/src/reloc.c`
- Modify: `/Users/.../avxemu/src/regfile.h` (declare `avxemu_relocate_block`)
- Modify: `/Users/.../avxemu/build.sh` (compile `reloc.c` into the core list)
- Test: `/Users/.../avxemu/test/reloctest.c` (new) + wire into `build.sh`

- [ ] **Step 1: Read the reuse surface**

Read `src/tramp.c` (`avxemu_build_thunk`, `avxemu_pool_init`/`avxemu_pool_base`, the
`tt`/`run_record`/`tramp_insn` machinery, `gather_run`, `x86_len`, `tramp_faults`,
`detect_features`), `src/tramp.s` (the `tt` spill/reload template), `src/decode.h`/`decode.c`
(`decoded`, `decode`), and `test/tramptest.c` (how a window is built, installed, run, and
checked). The relocator reuses the pool and the spill/reload template; do not duplicate
them.

- [ ] **Step 2: Write the failing round-trip test**

In `test/reloctest.c`, build a small executable buffer containing a window where the FIRST
instruction is a faulting BMI op and the next is a position-independent legal instruction,
followed by a `ret` (e.g. `lzcnt eax, edi` ; `neg dl` ; `ret`). Seed GPRs, run the
original via the emulator to get a reference end-state, then: call
`avxemu_relocate_block(buf)`, assert it returns 1, execute the patched buffer, and assert
the resulting GPRs/flags are bit-identical to the reference. Add a second case whose window
needs forward-extension across two legal instructions to reach 5 bytes. Follow
`tramptest.c`'s harness/assertion style. Build with `AVXEMU_FORCETRAMP` semantics so the
BMI op is treated as faulting on the Haswell host.

- [ ] **Step 3: Run it; verify it FAILS (symbol undefined)**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh 2>&1 | tail -30`
Expected: link failure — `avxemu_relocate_block` undefined.

- [ ] **Step 4: Implement `avxemu_relocate_block` (skeleton)**

In `reloc.c`:
1. Ensure the pool exists (call `avxemu_pool_init` with a near hint if `avxemu_pool_base()`
   is null, mirroring `tramp.c`).
2. **Decode the faulting instruction** at `site` (`decode`). If it doesn't decode or isn't
   a faulting op (`tramp_faults`), return 0.
3. **Build the window** `[site, end)`: starting at `site`, walk forward with `x86_len`
   accumulating whole instructions until `end - site >= 5`. While extending, each *added*
   instruction must be one the relocator can copy: for Task A accept only
   **position-independent** instructions (no ModRM RIP-relative operand, no relative
   branch — detect via the decoder / a small predicate; if an added instruction isn't
   safe, **return 0** = fall back to SIGILL). The first (faulting) instruction is handled
   by the stub, not copied.
4. **Verify the jmp footprint is safe**: no external branch target may land in
   `[site+1, site+5)`. For the runtime path you don't have the whole-function branch map;
   conservatively require that bytes `[site+1, site+5)` are covered by the instructions you
   gathered (i.e. the window's own instruction boundaries) and return 0 otherwise. (This is
   safe; it just declines awkward sites to the fallback.)
5. **Emit the relocated block** into the pool: (a) a spill→call→reload stub for the
   faulting instruction that calls `avxemu_emulate` with its `decoded` + a regfile, reusing
   the exact register-save/restore sequence from the `tt` template (factor a shared helper
   or emit the same bytes); (b) verbatim copies of the gathered legal instructions; (c) a
   `jmp` to `end`.
6. **Patch** `site` with `jmp rel32` to the block (page writable via `vm_protect`
   READ|WRITE|COPY, write `E9 rel32`, restore READ|EXECUTE — copy the exact pattern from
   `tramp.c`/`avxemu_patch_cpuid`). If `rel32` is out of range, return 0. Return 1.

Keep `reloc.c` focused; if it needs the same spill/reload bytes as `tramp.s`, expose a
small shared emitter rather than copy-pasting.

- [ ] **Step 5: Declare the entry**

In `regfile.h`: `int avxemu_relocate_block(uint8_t *site);  /* returns 1 if relocated */`.

- [ ] **Step 6: Run the test; verify PASS + suite green + VEX-clean**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh 2>&1 | tail -30`
Expected: `reloctest` passes; `[2] ... clean`; suite 0 failures.

- [ ] **Step 7: Commit**

```bash
cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu
git add src/reloc.c src/regfile.h build.sh test/reloctest.c
git commit -m "feat(avxemu): block-window relocation (emulator-stub core) + round-trip test"
```

### Task B: inline native lowerings for the 4 BMI ops (replace the stub on the hot path)

Speed: replace the per-instruction spill→emulate→reload stub with a short native sequence
for the ops the recon found, so the relocated block (esp. the loop site) runs at native
speed. Correctness is already guaranteed by Task A's fallback; this is a measured
optimization, oracle-gated.

**Files:**
- Modify: `/Users/.../avxemu/src/reloc.c` (a lowering table: `vex_op` → emitter)
- Test: `/Users/.../avxemu/test/reloctest.c` (extend)

- [ ] **Step 1: Write failing per-op lowering tests**

For each of `BMI_LZCNT`, `BMI_TZCNT`, `BMI_SHLX`, `BMI_ANDN`, at opsize 32 and 64, add a
`reloctest` case that relocates a one-faulting-instruction window and asserts the executed
result (destination value AND the CF/ZF flags those ops define) is bit-identical to
`bmi_exec` (the oracle-tested reference) over a spread of inputs including **0** (LZCNT/
TZCNT zero-input: result = opsize, CF=1) and all-ones. These must FAIL first (no inline
lowering yet — they exercise the stub, so initially they pass via the stub; to make them
"fail first" for TDD, gate the inline path behind a flag the test sets, or assert on a
marker that the inline emitter was used). Keep it honest: the test must verify the *inline*
sequence, not the stub.

- [ ] **Step 2: Implement the lowering table**

For each op emit a short native sequence using base-ISA instructions, preserving the
program's registers and flags except the op's defined outputs. Use a cache-local scratch
slot for any temp register and `pushfq`/`popfq`-style flag handling where the op must not
disturb flags (`SHLX` leaves flags unchanged; `ANDN`/`LZCNT`/`TZCNT` define specific
flags). Reference semantics are exactly `bmi_exec` in `src/exec_bmi.c`:
- `TZCNT`: `bsf` + zero-input fixup (→ opsize) + CF=(src==0), ZF=(result==0).
- `LZCNT`: `bsr` + `opsize-1-idx` + zero-input fixup (→ opsize) + CF/ZF.
- `SHLX`: shift-left by the count register, **flags unchanged**, no implicit `cl` clobber visible to the program.
- `ANDN`: `(~src1) & src2`, ZF/SF from result, CF=OF=0.
Anything not in the table falls through to Task A's stub.

- [ ] **Step 3: Run tests; verify PASS + full suite green**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh 2>&1 | tail -30`
Expected: all `reloctest` lowering cases pass; differential suite 0 failures; `[2] clean`.

- [ ] **Step 4: Commit**

```bash
git add src/reloc.c test/reloctest.c
git commit -m "feat(avxemu): inline native lowerings for LZCNT/TZCNT/SHLX/ANDN in relocator"
```

### Task C: fault-driven trigger in on_sigill

**Files:**
- Modify: `/Users/.../avxemu/src/handler.c`

- [ ] **Step 1: Add the RIP→count table + kill-switch (file scope in handler.c)**

```c
#define HOT_SLOTS 4096
#define HOT_THRESHOLD 50          /* faults at one RIP before we relocate it */
static struct { uint64_t rip; uint32_t n; } g_hot[HOT_SLOTS];
static int g_reloc_enabled = 1;   /* AVXEMU_RELOC=0 disables (A/B) */

static int hot_bump(uint64_t rip) {     /* 1 exactly when count crosses threshold */
    uint32_t i = (uint32_t)((rip * 0x9e3779b97f4a7c15ull) >> 52) & (HOT_SLOTS - 1);
    for (int probe = 0; probe < 8; probe++) {
        uint32_t k = (i + probe) & (HOT_SLOTS - 1);
        if (g_hot[k].rip == rip) return ++g_hot[k].n == HOT_THRESHOLD;
        if (g_hot[k].rip == 0)   { g_hot[k].rip = rip; g_hot[k].n = 1; return HOT_THRESHOLD == 1; }
    }
    return 0;                            /* slot region full: just keep emulating */
}
```

- [ ] **Step 2: Read the kill-switch in the constructor**

In `avxemu_install()`, after the existing env reads:
```c
{ const char *r = getenv("AVXEMU_RELOC"); if (r) g_reloc_enabled = (r[0] != '0'); }
```

- [ ] **Step 3: Trigger after emulating the faulting instance**

In `on_sigill`, after the successful `avxemu_emulate(&d, &rf)` and state write-back (so
this instance is already correct), before returning:
```c
if (g_reloc_enabled && hot_bump(base)) avxemu_relocate_block((uint8_t *)base);
```
(`avxemu_relocate_block` is declared via `regfile.h`, already included.)

- [ ] **Step 4: Build; full suite green**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh 2>&1 | tail -20`
Expected: builds clean; `[2] clean`; 0 failures.

- [ ] **Step 5: Commit**

```bash
git add src/handler.c
git commit -m "feat(avxemu): fault-driven hot trigger -> avxemu_relocate_block (AVXEMU_RELOC)"
```

### Task D: build dylib + point launcher at it

- [ ] **Step 1:** `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh 2>&1 | tail -5; ls -la /tmp/avxemu/libavxemu.dylib` — confirm a fresh dylib.
- [ ] **Step 2:** Inspect `scripts/claude_185` (this repo); ensure it injects the freshly built `libavxemu.dylib` (copy `/tmp/avxemu/libavxemu.dylib` to the injected path if needed). No app-config changes.

---

## Phase 3 — end-to-end verification

### Task E: pyte A/B (relocation off vs on, ≥3×), record, reconcile

**Files:** Modify (record): `docs/RULED-OUT.md`, `docs/STARTUP-HANG-OPTIONS.md`.

- [ ] **Step 1: Control — `AVXEMU_RELOC=0`, 3×** (fetch 2.1.185 first if reaped). Trust the test dir; run `AVXEMU_RELOC=0 LAUNCHER=scripts/claude_185 python3 scripts/pyte_watch.py 60` ×3; expect CPU pegs for the usual minutes-long spin. Restore `~/.claude.json`.
- [ ] **Step 2: Treatment — relocation on (default), 3×.** Same without `AVXEMU_RELOC=0`; expect CPU decays to idle within a few seconds. Run `LAUNCHER=scripts/claude_179 pyte_watch.py 60` once as the parity reference.
- [ ] **Step 3: Interactivity.** With relocation on, `scripts/pyte_type.py`, type, confirm prompt echo. Restore `~/.claude.json`.
- [ ] **Step 4: If still pegged — diagnose, don't thrash.** Re-run the `si_addr` capture (the Phase-1 method, not leaf-PC) with relocation on: are the 4 sites gone from the histogram? If a *new* dominant faulting site appears, relocate it too (it's the same mechanism). If a site won't relocate (relocator returns 0 — log why: unsafe window / out-of-range / unsupported legal instr), that's the entry criterion for **Task D-reloc-fixup** (RIP-relative + branch relocation, widening windows) or, if it's a large dense-faulting region, for the **deferred full DBT** (spec §9 breadcrumb).
- [ ] **Step 5: Record + reconcile.** Update `docs/RULED-OUT.md` and `STARTUP-HANG-OPTIONS.md` with before/after CPU and the mechanism. Commit in this repo:
```bash
git add docs/RULED-OUT.md docs/STARTUP-HANG-OPTIONS.md
git commit -m "docs: block-window relocation result (trusted startup -> parity)"
```

---

## Self-review notes (for the executor)

- **Correctness rides on the oracle + the abort-to-fallback rule.** Task A reuses
  `avxemu_emulate` (already green) for the faulting op and copies only position-independent
  legal instructions; anything else → return 0 → existing SIGILL path. No regression is
  possible from declining a site. Task B's inline lowerings are gated by per-op differential
  tests vs `bmi_exec`.
- **The real unknown is Task E Step 4:** whether relocating the 4 known sites (plus the
  existing trampoliner handling the ≥5-byte `shlx`/`andn`) makes the loop and dispatch
  paths trap-free enough for parity. The diagnostic (si_addr with reloc on) decides whether
  we widen the relocator (fixup) or escalate to the DBT.
- **Reuse over re-implement (DRY):** share the `tt` spill/reload bytes between `tramp.s` and
  `reloc.c`'s stub; reuse the pool and `decode`/`x86_len`. Preserve the `AVXEMU_FULLTHUNK` WIP.
- Restore `~/.claude.json` after every trusted run; repeat CPU measurements ≥3×.
```
