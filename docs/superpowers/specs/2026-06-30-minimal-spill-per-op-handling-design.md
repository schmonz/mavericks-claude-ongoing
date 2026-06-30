# Minimal-spill per-op handling (Phase 1) → hot-region translation (Phase 2) — Design

**Status:** approved design (2026-06-30). Implements the **leading hypothesis** in
`docs/RULED-OUT.md` ("★ LEADING HYPOTHESIS"): the no-AVX2 startup spin is the **per-op
trampoline overhead (spill/reload), not the emulation math, not the app JS.**

**Required reading:** `docs/RULED-OUT.md` (esp. the "★ LEADING HYPOTHESIS" section and the
2026-06-30 entries) and `docs/STARTUP-HANG-OPTIONS.md` banner. This supersedes, as the active
plan, the emulation-*math* approaches (Milestones A & B), which are correct infra but
optimized the part that didn't matter.

---

## 1. Problem & goal

On the no-AVX2 Ivy Bridge target, trusted .185 startup pegs a core for minutes; the same
.185 on AVX2 hardware (taavibookair, our baseline) starts fine. Measurement established:
- It is **pure compute** (~0 syscalls), not a trap storm and not a deadlock.
- Eliminating the emulation **math** (native codegen, "native-ON") changed nothing —
  native-ON ≈ native-OFF, both peg ≥240s — because **both reach each op through the same
  full-register spill/reload trampoline frame.** The math was never the cost.
- AVX2 hardware pays **zero** per-op overhead (ops are inline), and is fine. So the entire
  gap is the per-op handling overhead on the emulated path.

**Goal:** make each emulated AVX2/BMI op pay near-hardware per-op cost by replacing the
full-register-spill trampoline frame with a **minimal per-op frame that operates on the live
registers in place**, saving only the scratch each op's lowering actually clobbers. Success =
trusted .185 startup on the target reaches idle in a few seconds (taavibookair-grade), in a
trust-verified long-window A/B.

## 2. The architectural shift (the core idea)

**Today:** a faulting op is patched to `jmp` a *fixed* thunk template (`tt` = spill all 16
ymm; `tt2` = spill all 16 gpr + flags) → the op runs against the spilled regfile (C-emulate
or, post-Milestone-B, an emitted native block) → all registers reload → `jmp` back. The
full spill/reload is paid **per op, every iteration** — the hypothesized cost.

**New (minimal-spill, live-register):** emit a *per-op* thunk that:
1. saves ONLY the scratch registers (and only the flag bits) that this op's native lowering
   clobbers — typically 1–3 registers, via push/pop or a red-zone-safe slot;
2. runs the native lowering **on the live operand registers in place** (e.g. `lzcnt eax,edi`
   → `bsr`/fixup writing the real `eax`, reading the real `edi`); 256-bit vector halves via
   AVX1 `vextractf128`/`vinsertf128` (present on the target);
3. restores the saved scratch/flags;
4. `jmp`s back to the resume address.

This is what hardware does, minus a tiny scratch save — no regfile, no all-register spill.
It reuses the **math** of the lowerings already built and oracle-gated in Milestone B
(`lzcnt`→`bsr`+fixup; `vpbroadcastw`→`movd`/`pshuflw`/`pshufd`); the change is the *frame*
(what gets saved) and the *operand targets* (live registers, not regfile slots).

## 3. Components

1. **Per-op clobber metadata** — for each supported op, the exact set of scratch GPR/XMM
   registers and flag bits its live-register lowering touches. The minimal thunk saves
   precisely this set. (We author the lowerings, so the set is known and fixed per op.)
2. **Minimal-spill thunk emitter** — given a `decoded` op and its clobber metadata, emits
   into the RWX pool: `[save clobbered scratch + undefined-flag preservation]` →
   `[inline live-register native lowering]` → `[restore]` → `[jmp resume]`. Position-
   independent; uses the existing pool allocator and the existing 5-byte-`jmp` site patch +
   `avxemu_patch_safe` guard.
3. **Live-register lowerings** — the Milestone-B lowering math retargeted from regfile slots
   to live operand registers, with correct flag semantics (e.g. LZCNT defines CF/ZF/SF/OF →
   the thunk preserves only PF/AF and any other live flags; capture CF before `bsr`; handle
   `dst==src`). One per supported op.
4. **emit_run wiring** — when a faulting op has a minimal-spill live-register lowering and
   the site is `avxemu_patch_safe`, use the minimal thunk; otherwise fall back to the
   existing full-spill thunk / C dispatch (no regression). Gated by an env toggle
   (e.g. `AVXEMU_MINSPILL`, default off until proven, then on) for clean A/B.

Each unit is independently testable: the lowering math (vs oracle), the minimal thunk frame
(save/restore correctness), and the wiring/fallback.

## 4. Phase 1 — staged, lzcnt-first, with a hard gate

- **1a — lzcnt only.** Build the minimal-spill live-register `lzcnt` thunk; oracle-gate vs
  `bmi_exec` (result + CF/ZF/SF/OF, PF/AF preserved, zero-input, `dst==src`). Then the
  **GATE** — a trusted long-window A/B (time-to-idle, ≥3×, trust verified each run, isolated
  dylib):
  - **Confirm:** removes ~half the spin (lzcnt ≈ 46.8% of emulated ops) → the per-op-spill
    hypothesis is confirmed → proceed to 1b.
  - **Refute:** ~0 change → the spill is NOT the per-op cost → **STOP and reassess** (the
    per-op `jmp` round-trip or another mechanism dominates) → go to Phase 2 evaluation or
    re-profile. **Do not build more ops on an unconfirmed premise** (the prior mistake).
- **1b — vpbroadcastw** (≈46.8%): minimal-spill live-register lowering (2×128 SSE + AVX1 for
  the high half) → A/B; expect cumulative ~93.6% of emulated-op overhead removed → near
  parity.
- **1c — tail** (`mulx`, `shlx`, `bzhi`, `tzcnt`, `blsr`, `andn`, `shrx`; then
  `vpbroadcastb`/`vpbroadcastq`, `vpmovmskb`, `vextracti128`, `vpaddq`) only as far as needed
  to reach parity. Each op: live-register lowering + oracle + A/B increment.

## 5. Phase 2 — hot-region / loop translation (planned, not-forgotten fallback)

**Trigger (explicit, recorded so it is not silently dropped):** if minimal-spill has been
applied to the dominant hot ops **and** trusted long-window A/B still shows the spin, **and**
profiling shows the residual cost is the per-op `jmp`/round-trip itself (not spill, not math),
THEN build hot-region translation: detect the hot loop/region, translate its faulting ops
inline into one native block run across iterations with vector/GPR state kept in registers —
**zero per-op round-trip**, the closest to hardware. This is the deferred full-DBT direction;
it gets its own spec/plan when triggered. Until the trigger fires, Phase 1 is the work.

## 6. Testing & guardrails (apply to every task)

- **Correctness:** oracle-gate every live-register lowering vs `bmi_exec`/`vec_exec`
  on-target (the `nativetest`/`reloctest` harness pattern), AND run the full silicon
  differential suite (`build.sh`) on **taavibookair** before shipping any dylib. Keep the
  per-task adversarial code review for machine-code-emitting changes (it caught 3 Criticals
  across Milestones A/B).
- **A/B methodology (hardened — these caused false positives before):**
  1. **Verify trust intact before EVERY run** (an untrusted project idles at the gate and
     fakes a "fix"); a valid A/B requires the control to reliably PEG.
  2. **Long-window time-to-idle**, not a 60s snapshot (the spin is minutes).
  3. Isolated dylib (`/tmp/avxemu_*`) + `scripts/claude_185_natslice` + env toggle; never
     touch the live `$MF` dylib (`cp`-over crashes running sessions — atomic `mv` to ship);
     never broad-`pkill` (kills the user's other sessions — kill only the exact child PID).
  4. ≥3× per condition; bimodal/noisy system.
- **Secondary signal:** effective ns/op (op count from `AVXEMU_OPHIST` ÷ wall time) vs the
  ~1-cycle hardware cost, to quantify how close to parity each increment gets.

## 7. Out of scope (YAGNI)

- Emulation-math optimization (done in Milestone B; ruled out as the lever — ~0 benefit).
- App-side / JS investigation, clode/Node escape (clode not a durable target per user; the
  baseline proves the JS is fine natively).
- Full region translation up front — deferred to Phase 2 behind its explicit trigger.
