# mavericks-claude-ongoing

Ongoing work to make upstream **Claude Code** usable on a **no-AVX2 Mac** (Ivy
Bridge / OS X 10.9.5) via the Mavericks launcher + `libavxemu` (AVX2 trap-and-emulate).

**Current problem:** Claude Code **2.1.183+** pegs a core for minutes at startup on
any *trusted* project and the TUI is ~unusable. **2.1.179 does not** — a clean
version regression.

> **Root cause — CORRECTED 2026-06-30 (supersedes the old "slow emulated AVX2" story).**
> The spin is **NOT** dominated by AVX2 emulation. Measurement (trusted dtrace A/B + PC
> profile): it's **pure compute** (~0 syscalls), emulation is only **~32%** of it, and
> eliminating emulation entirely (native codegen, verified) does **not** collapse it —
> native-ON and native-OFF both peg ≥240s while 179 idles. The bottleneck is **Bun(JSC)'s
> JIT'd execution of one ~2KB hot loop** from the 179→183 app regression; the same .185 JS
> runs fine on clode/Node ⇒ **Bun-runtime-specific, not algorithmic, not "no-AVX2".**
> **LEADING HYPOTHESIS (2026-06-30 latest):** the cost is the **per-AVX2-op trampoline
> overhead (spill/reload), not the emulation math.** AVX2 hardware runs .185 fine (zero per-op
> overhead); native-ON ≈ native-OFF because both pay the same spill frame (native only changed
> the cheap math → ~0 benefit). So emulation-**math** optimization is ruled out, but
> **eliminating the per-op spill (minimal-spill thunks / hot-region translation, no per-op
> round-trip) is the live, untested lever** — the spike measured no-spill at ~50–65×. The
> earlier "app-side / avxemu ruled out / ~1.5× ceiling" read was an over-correction. See
> `docs/RULED-OUT.md` → "★ LEADING HYPOTHESIS".

## Start here (read in this order)

1. **`docs/STARTUP-HANG-OPTIONS.md`** — the fresh-agent BRIEF. Constraints (what's
   settled, what's noise, what walls exist), the reliable repro, and the two fix
   tracks. **Read it fully before running anything.**
2. **`docs/RULED-OUT.md`** — the detailed eliminated-list (don't re-derive these).
3. **`docs/superpowers/plans/2026-06-28-avxemu-startup-spin-fix.md`** — the task-by-task implementation
   plan (Track C native shim, with a native-vs-JIT decision gate; Track D as fallback).
4. **`scripts/README.md`** — the harnesses + launchers and a one-breath repro.
5. **`docs/evidence/`** — raw captures (native sample, 179 vs 183 startup debug logs).
6. **`docs/IDEAS.md`** — deferred ideas not yet planned (e.g. scoping the shim to one binary so it stops crashing child `node`).

## Layout

```
docs/                    STARTUP-HANG-OPTIONS.md (brief), RULED-OUT.md, evidence/
docs/superpowers/plans/  the implementation plan (superpowers-conventional path)
scripts/                 pyte_*.py harnesses, catch-spin.sh, hot-offset.sh, claude_* launchers, fetch-version.sh
```

## Assumptions for a fresh agent

- **cwd = this repo.** Tools are self-contained (harnesses resolve their launcher
  relative to `scripts/`). Only runtime scratch uses `/tmp`.
- External siblings referenced by absolute path:
  - avxemu + shim source: `../Mavericks-Porting-Resources/` (the fix goes here).
  - extracted JS bundles (static-diff fallback): `../clode/build/2.1.<v>/cli.cjs`.
- Discipline: this system is **bimodal/noisy** — repeat every measurement ≥3×, never
  conclude from one run, and consult the brief before each experiment. The two prior
  sessions burned time re-deriving the settled nature and chasing noise (plugins/
  skills/hooks/terminal-queries were all dead ends — see the brief's DO-NOT lists).

## Status

Localized to a trusted-startup emulated-AVX2 hot loop; naming the exact JS call is
blocked by tooling (stripped binary + JIT frames + the inspector wall). The plan does
NOT need the JS name — it identifies the hot *native* routine by offset and either
shims it (Track C) or JITs hot loops in the emulator (Track D), either of which can
plausibly bring startup to a few seconds.
