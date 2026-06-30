# HEROIC-OPTIONS — the hard-path playbook (if minimal-spill isn't enough)

**When to read this:** only if the Phase-1a gate
(`docs/superpowers/plans/2026-06-30-minimal-spill-lzcnt-gate.md`) **refutes** — i.e. removing
the per-op spill (and, by extension, cheap per-op fixes) does NOT collapse the spin — so we're
facing the genuinely hard case: the AVX2/BMI cost is tied up in the Bun(JSC)-JIT'd hot loop and
can't be made cheap one op at a time. This is the "arbitrarily heroic" menu. Until that gate
fails, this doc is not the work — the plan is.

**Prereqs / settled facts this builds on** (see `docs/RULED-OUT.md`): the spin is pure compute;
it's AVX2/BMI-handling on a no-AVX2 CPU (AVX2 hardware runs .185 fine; .179 runs fine under the
same emulator → the problem is finite and bounded, not a wall); the hot loop PC sits in a
JSC-JIT'd anonymous region while the *faulting sites we localized were in static `__TEXT`*
(scalar BMI) — that nuance routes the options below.

---

## The reframe: ELIMINATE the AVX2, don't out-engineer its emulation

The instinct ("translate the JIT'd region") is the *harder* philosophy. The smarter heroic
play is usually to **make the AVX2 stop existing** (stop JSC emitting it / rewrite it away)
rather than make emulating it fast — because that dissolves the volatile-JIT-code problem
instead of fighting it, and it makes the unresolved "is it the spill or the round-trip?"
question irrelevant. Tiers are ordered by that principle: eliminate first, translate only if
forced.

---

## TIER 1 — Eliminate the AVX2 at its source (preferred; static, no live-code translation)

### 1a. Force JSC's JIT to emit SSE-baseline code
JSC vectorizes based on a CPU-feature check; if it believes there's no AVX2 *for codegen*, it
emits baseline SSE/scalar that runs **natively at full speed** — nothing to trampoline or
translate.
- **Cheap first (try before any heroics):** a JSC/Bun option or env that disables the AVX2
  codegen path or caps the JIT tier. We already pass `JSC_numberOfGCMarkers=1`, so the channel
  exists; look for a JSC `Options::useAVX`-style flag or a Bun passthrough.
- **Heroic:** patch JSC's JIT feature-gate **in the static `__TEXT`** (which we can already
  patch via the existing Mach-O/code-patch tooling) so the emitter takes its non-AVX2 branch.
  This is a *static* patch — no volatile-code problem at all.
- **Feasibility gate:** can we locate JSC's codegen feature-gate in the stripped Bun binary,
  and does forcing baseline produce correct output? (JSC supports non-AVX2 CPUs generally, so
  the baseline path should exist.)
- **Why it's the top pick:** converts "emulate volatile AVX2 fast" into "no AVX2 emitted,"
  sidestepping the entire hard problem.

### 1b. AOT-rewrite the static `__TEXT` AVX2 once per version
The faulting sites we localized are scalar BMI in static builtins — patchable. Rewrite them to
SSE at install/patch time (the launcher/update path can automate it), eliminating their per-op
handling entirely.
- **Combined with 1a → total elimination of AVX2 execution** (JIT-emitted *and* builtin) with
  **zero runtime DBT.** Two static interventions. This combo is the heroic sweet spot.
- **Durability:** re-apply per upstream version; op-agnostic rewriter is more durable than
  per-offset shims.

---

## TIER 2 — Translate the AVX2 (the genuine hard path, only if elimination is impossible)

If AVX2 must actually be executed and can't be suppressed, translate it — but manage the
volatility cleverly.

### 2a. Hook JSC code-finalization; patch AVX2→SSE at EMIT time
JSC makes JIT code executable via an `mprotect`/`mmap` RX transition. Interpose that moment —
when the code is quiescent, just-born, not yet running — and rewrite its AVX2/BMI → inline SSE
right there, re-doing it on each fresh emission. Avoids the "patch code mid-execution" hazard
that sank the naïve approach (you edit before it ever runs).
- **Feasibility gate:** can we reliably interpose JSC's executable-memory finalize/`mprotect`
  path and identify the AVX2 sites in the fresh block fast enough?

### 2b. Full trace/region JIT with a translation cache (last resort)
The QEMU/DynamoRIO model: detect hot regions, translate once into native SSE blocks in a cache
keyed by source bytes, run inline (state in registers, no per-op round-trip), invalidate /
re-translate when JSC moves or frees the code.
- Proven *possible* (DBTs do exactly this), but the invalidation bookkeeping against a hostile
  GC/deopt is the real cost. This is the deferred "Phase 2 / full DBT" from the minimal-spill
  spec. Reach for it only if 2a isn't viable.

---

## The routing diagnostic (decides Tier 1 vs Tier 2)

**Is the hot AVX2 JSC-JIT-EMITTED, or is it in static `__TEXT` builtins the JIT loop merely
calls a lot?** Our `si_addr` recon found the faulting sites in *static* `__TEXT` (scalar BMI),
with the *caller* in the JIT region. If that holds:
- the AVX2 is in **patchable static code** → **Tier 1b** handles it, and
- the residual is the call/round-trip per iteration → **Tier 1a** (stop JSC emitting the
  vectorized caller) or **2a**.
- The genuinely-hard **2b** full DBT is forced ONLY if substantial AVX2 is truly *born and run
  inside* volatile JIT code. Confirm this with the user-PC-by-region profile + a check of
  whether the JIT block itself contains AVX2 bytes vs only `call`s into static builtins, BEFORE
  committing to 2b.

---

## Recommended ordering if we hit the wall

1. **1a cheap flag** (an afternoon — try before any heroics).
2. **1a + 1b heroic (make AVX2 not exist via static patches)** — less code AND less risk than
   translating live code; makes the spill/round-trip question irrelevant.
3. **2a** (emit-time patch hook) if AVX2 really is JIT-emitted.
4. **2b** (full DBT) only as the last resort.

Heroic should still mean *clever*: dissolving the problem (Tier 1) beats out-engineering it
(Tier 2).

---

## DEAD — do not propose (ruled out by the user)

- **Tier 3 — build a no-AVX2 Bun from source ("blode") / any repackaging of the runtime.**
  DEAD. (Faithful in principle, but ruled out — destined to rot / not a durable target.)
- **Tier 4 — upstream fix / baseline-compiled artifact / external leverage.** DEAD. (Out of
  our hands; not pursued.)
- (Earlier, also dead, per `docs/RULED-OUT.md`): clode/Node as the daily driver; pinning .179
  as the fix. Both are temporary instruments, not the goal.
