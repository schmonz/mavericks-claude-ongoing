# avxemu Faulting-Site Block-Window Relocation — Design

**Status:** approved design (revised 2026-06-29 after Phase-1 measurement + site recon).
**Supersedes** the per-offset shim approach (old Track C) and the *original* version of this
spec, which assumed the hot path was AVX2-vector and JSC-JIT'd. **Both assumptions were
wrong** (see §2). This revision targets what the binary actually does.

**Required reading:** `docs/STARTUP-HANG-OPTIONS.md` (brief), `docs/RULED-OUT.md`,
`docs/hot-routine.md` (Phase-1 measurement + the 4-site byte-level recon this design is
built on).

---

## 1. Goal & success criteria

Make trusted-project startup of the **latest** upstream Claude Code on the no-AVX2 Mac
(Ivy Bridge / OS X 10.9.5, via the Mavericks launcher + `libavxemu`) match **2.1.179** —
minutes-and-unusable → a few seconds and responsive — by making the faulting instructions
that currently can't be trampolined run **trap-free**, via a general mechanism that is
durable to where/how upstream emits faulting code in future versions.

**Gates (evidence before claims — bimodal/noisy, repeat ≥3×):**
- **Correctness:** the differential oracle (`build.sh` on a Haswell box) stays at **0
  failures, bit-exact**, for every instruction lowering AND for a new relocation
  round-trip test (relocated block ≡ original block).
- **Performance:** pyte CPU A/B (`scripts/pyte_watch.py`, ≥3×) shows trusted startup decay
  to idle in a few seconds with relocation on, vs. pegged with it off; responsive TUI.

## 2. What the measurement actually found (corrects the old premise)

Phase 1 (si_addr histogram from the SIGILL handler — authoritative for `#UD`) + a
byte-level recon of the 4 dominant faulting sites established:

- **The hot path is scalar BMI/ABM, not AVX2-vector.** Every dominant faulting
  instruction is `LZCNT`, `TZCNT`, `SHLX`, or `ANDN`. No `ymm`, no FMA, no F16C. (The
  AVX2-vector ops *are* already trampolined by the load-time scanner — trampoline hits
  outnumber SIGILL traps 11–39×. The residual spin is these scalars.)
- **The miss is structural, not a coverage gap.** `LZCNT`/`TZCNT` are **4-byte**
  instructions (legacy `F3 0F BD/BC`). The existing trampoliner can only redirect a run
  of faulting instructions that is **≥5 bytes** (room for `jmp rel32`). An isolated 4-byte
  faulting instruction has nowhere to put the jump, so it **cannot be made trap-free
  today** and falls to per-instruction SIGILL emulation (~57µs each) forever. avxemu
  already *emulates* these correctly (`bmi_exec`; `avxemu_patch_lzcnt` forces them to
  fault so they aren't silently mis-run as `BSR`/`BSF`) — the gap is purely "can't patch a
  too-short site."
- **One site is a hot loop.** Site 4 is a ~125-byte set-bit-iteration loop
  (`tzcnt`/`shlx`/`andn`, with an indirect `call`) that traps every iteration. Sites 1–3
  are straight-line/dispatch code. There is exactly **one `__TEXT` segment** (the
  "2nd-segment" theory is dead).

**Implication:** the durable fix is a mechanism that can make an **isolated, sub-5-byte
faulting instruction (and a faulting loop) trap-free** — generally, regardless of op or
placement. That is block-window relocation.

## 3. Speedup model (math unchanged; reframed to BMI traps)

dtrace: ~17K traps/s, ~57µs each, dominated by SIGILL-delivery + sigreturn — *the cost is
the kernel trap round-trip, independent of which instruction faults*. The residual BMI
traps consume ~0.4–3.6s per 4s window today; over a multi-minute startup that is the spin.
Eliminating the trap (relocate → run native) collapses it: the straight-line sites stop
trapping on every reach, and the loop runs entirely in native code (one redirect at the
header instead of N×3 traps). **End-to-end is Amdahl-bounded** at the ~3.6s of normal
non-AVX startup work 179 also does — so the target is **179 parity**, which is the goal.

## 4. The mechanism: block-window relocation

A single general primitive, `avxemu_relocate_block(site)`, that the existing pool/patch
machinery feeds:

1. **Pick a window** `[site, end)` of whole instructions where the faulting instruction is
   **first**, extending *forward* over following instructions until `end - site ≥ 5`
   (room for `jmp rel32` at `site`). For a loop site, the window start may instead be the
   **loop header** (a branch target, already a safe boundary) so the back-edge re-enters
   the relocated copy. Reuse the scanner's existing control-flow analysis (`lde_cflow`,
   the per-function branch-target map in `scan_function`) to verify **no external branch
   targets land inside the jmp footprint** `[site+1, site+5)`. (External branches to
   `site` itself, or to `≥ site+5`, remain correct — those original bytes are untouched.)
2. **Emit a relocated copy** of the window into the RWX code cache (the existing
   `avxemu_pool_*`). For each instruction:
   - **faulting** → emit its **native lowering** from an extensible table (Milestone A:
     `LZCNT`, `TZCNT`, `SHLX`, `ANDN` — each a short, bit-exact scalar sequence; e.g.
     `LZCNT`/`TZCNT` via `BSR`/`BSF` + documented zero-input/flag fixups). For a faulting
     op **not** in the table (future-proofing), emit a **spill→`avxemu_emulate`→reload
     stub** (correct via the existing oracle-tested core; slower but trap-free), or, if
     even that isn't safe, **abort relocation** for this site (it stays on SIGILL
     emulation — no regression).
   - **legal** → **copy verbatim**, fixing up RIP-relative displacements (recompute for
     the new location) and relative branch targets (retarget to the original absolute
     address). Register-indirect calls/jumps (e.g. site 4's `call *%rax`) are
     position-independent and copy as-is.
3. **Append `jmp end`** (back to the original resume point) to the cache copy.
4. **Patch** `site` (page made writable via `vm_protect`, as the existing patcher does)
   with `jmp rel32` to the cache copy. The thunk pool sits within `jmp rel32` reach of
   `__text` (single segment, confirmed), so no far-island is needed.

This is a strict generalization of the existing run-trampoliner: that one only relocates
runs of *faulting* instructions ≥5 bytes; this one **includes surrounding legal
instructions to reach the 5-byte threshold**, which is exactly what isolated short sites
require — and it handles loops by relocating the body and redirecting the header.

## 5. Trigger & coverage (source-agnostic = durable)

- **Fault-driven (primary, the durable catch-all):** a RIP→count table in `on_sigill`;
  once a faulting site is hot, call `avxemu_relocate_block(rip)`. This reacts to the
  *empirical fault* — it does not care *why* the site wasn't pre-trampolined (too short,
  dirty function, jump-table-adjacent, a future segment layout, or hypothetically
  runtime-JIT'd code). One mechanism covers all of them.
- **Eager pre-warm (optional follow-on):** generalize the load-time scanner's `emit_run`
  to also relocate isolated short faulting sites via the same primitive, so common sites
  never take even one trap. Not required for the goal; deferred unless Task-7 data wants
  it.

## 6. Native lowerings (Milestone A op set; oracle-gated)

`LZCNT`, `TZCNT`, `SHLX`, `ANDN` — all scalar GP-register, opsize 32/64. Each lowering is
a short native sequence whose semantics match `bmi_exec` exactly (including LZCNT/TZCNT
zero-input results and the CF/ZF flag effects). The table is the extension point: adding a
future faulting op = adding one lowering + one oracle test. Until then, unknown faulting
ops use the emulator-call fallback (§4.2), so correctness is never gated on the table
being complete.

## 7. Verification

- **Per lowering (TDD):** failing differential test first (extend `test/oracle.c` /
  `test/bmi_oracle.c`), implement, green — vs. real silicon on the Haswell host.
- **Relocation round-trip (new test):** build a window of mixed faulting + legal
  instructions (including a RIP-relative `lea`, a relative branch, and a small loop),
  relocate it, execute both original-semantics and relocated copy from identical register/
  memory state, assert bit-identical results. Model it on `test/tramptest.c`.
- **No regressions:** full `build.sh` suite stays 0-failures; core stays VEX-clean.
- **End-to-end:** pyte CPU A/B on trusted 2.1.185, ≥3×, relocation on vs off
  (`AVXEMU_RELOC=0` kill-switch); confirm parity + responsiveness.

## 8. Risks

- **Verbatim relocation of arbitrary legal x86 is the hard part** (RIP-relative + relative
  branches need fixup; some instructions resist relocation). Mitigation: the windows are
  small (1 faulting instr + a few legal for sites 1–3; one ~125-byte loop for site 4);
  start with the instruction shapes the recon actually shows, and **abort relocation
  (fall back to SIGILL emulation) for any instruction the relocator doesn't positively
  know how to move** — correctness first, speed where safe.
- **Self-modifying / re-JIT'd target** (not seen — code is static `__TEXT`): a byte-keyed
  validity check on patched sites can be added if ever observed; deferred (YAGNI).

## 9. Out of scope (YAGNI) + breadcrumb for the deferred ambitious path

- **Repackaging** onto a different runtime (clode/Node/own Bun) — clode stays an RE tool.
- **Per-named-routine shims** (old Track C); app-config/plugins/etc. (ruled out).
- **AVX2-vector native codegen** — the vector path is already trampolined; revisit only if
  a future version surfaces un-trampolinable vector sites (the relocation table extends to
  cover them when it does).

### Breadcrumb — the more-ambitious alternative NOT chosen (2026-06-29)

When picking the relocation mechanism's depth, the considered-but-deferred option was a
**full control-flow-following dynamic binary translator (DBT)**: trace/region formation
that *follows branches* across basic blocks, performs cross-block register allocation, and
relocates arbitrary control flow into the code cache (a mini-Rosetta for the faulting-op
subset). It is strictly more general than block-window relocation — it would also win for
large hot regions with dense cross-block faulting, and (with a fault-driven entry) for
genuinely runtime-JIT'd faulting code.

It was **deferred, not rejected**, because the measured hot set is tiny (4 scalar ops,
mostly straight-line + one small loop) and block-window relocation covers it durably at a
fraction of the effort. **Revisit the DBT if** Milestone A's pyte A/B leaves residual spin
that per-window relocation can't close, or a future upstream version's faulting profile
outgrows isolated windows. This is the natural "next heroic tier" — the way avxemu itself
was the previous one. (Cross-referenced from `docs/RULED-OUT.md`.)
