# mavericks-claude-ongoing

Ongoing work to make upstream **Claude Code** usable on a **no-AVX2 Mac** (Ivy
Bridge / OS X 10.9.5) via the Mavericks launcher + `libavxemu` (AVX2 trap-and-emulate).

**Current problem:** Claude Code **2.1.183+** pegs a core for minutes at startup on
any *trusted* project and the TUI is ~unusable. **2.1.179 does not** — a clean
version regression. Root cause is settled: it's *correct but catastrophically slow
emulated AVX2* (per-instruction SIGILL trap tax). The fix is heroic and lives in
avxemu, not in app config.

## Start here (read in this order)

1. **`docs/STARTUP-HANG-OPTIONS.md`** — the fresh-agent BRIEF. Constraints (what's
   settled, what's noise, what walls exist), the reliable repro, and the two fix
   tracks. **Read it fully before running anything.**
2. **`docs/RULED-OUT.md`** — the detailed eliminated-list (don't re-derive these).
3. **`plans/2026-06-28-avxemu-startup-spin-fix.md`** — the task-by-task implementation
   plan (Track C native shim, with a native-vs-JIT decision gate; Track D as fallback).
4. **`scripts/README.md`** — the harnesses + launchers and a one-breath repro.
5. **`docs/evidence/`** — raw captures (native sample, 179 vs 183 startup debug logs).

## Layout

```
docs/      STARTUP-HANG-OPTIONS.md (brief), RULED-OUT.md, evidence/
plans/     the implementation plan
scripts/   pyte_*.py harnesses, catch-spin.sh, hot-offset.sh, claude_* launchers, fetch-version.sh
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
