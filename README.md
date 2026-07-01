# mavericks-claude-ongoing

Making upstream **Claude Code** usable on a **no-AVX2 Mac** (Ivy Bridge / OS X 10.9.5)
via the Mavericks launcher + `libavxemu` (AVX2 trap-and-emulate).

**The problem:** Claude Code **2.1.183+** pegs a core for minutes at startup in any
*trusted* project — **2.1.179 does not** (a clean version regression). The TUI renders,
but a background loop spins.

## Current state lives in the live docs (this README stays deliberately thin)

The investigation moves fast, so the authoritative, always-current status is kept out of
here on purpose. Read, in order:

1. **`docs/RULED-OUT.md`** — **the source of truth.** Its top section is the latest
   findings + verdicts; the body is the eliminated-list and every dead end (including the
   **"JS-LEVEL PROFILING ATTEMPTS LOG"** — what was tried and how *not* to repeat it).
2. **the `start-here` auto-memory** — loaded at session start; carries the current
   **NEXT ACTION** and handoff state for a fresh agent.
3. **`docs/STARTUP-HANG-OPTIONS.md`** — the BRIEF: constraints, what's settled, what's
   noise, tooling walls, and the reliable repro. Read before running anything.

> One-line framing as of 2026-07-01 (trust `RULED-OUT.md` over this if they diverge): the
> spin is **Claude's own startup JavaScript** (string-heavy, in the JSC interpreter), **not**
> the AVX2 emulation — emulation optimization is ruled out. Naming the exact JS function is
> the open task. Everything else (specs/plans under `docs/superpowers/`) is historical unless
> `start-here` says otherwise.

## Layout

```
docs/                RULED-OUT.md (source of truth), STARTUP-HANG-OPTIONS.md (brief), evidence/, IDEAS.md
docs/superpowers/    specs + plans (historical + active — check dates against start-here)
scripts/             pyte_*.py harnesses + claude_* launchers (self-resolving; run from repo root)
```

## Working assumptions (stable)

- **cwd = this repo.** Harnesses resolve their launcher relative to `scripts/`; runtime
  scratch uses `/tmp`. External siblings by absolute path: avxemu + shim source
  `../Mavericks-Porting-Resources/`; extracted JS bundles `../clode/build/2.1.<v>/cli.cjs`.
- **Discipline (this system is bimodal/noisy):** repeat every measurement ≥3×, verify
  project **trust** before each run, never conclude from one run, and keep runs
  **commensurate** — same version / binary / login / harness. Mismatches here have produced
  wrong conclusions more than once. Hard safety rules (never `cp`-over the live
  `$MF/libavxemu.dylib`; never broad-`pkill`) are spelled out in the brief and `RULED-OUT.md`.
