# mavericks-claude-ongoing

Making upstream **Claude Code** usable on a **no-AVX2 Mac** (Ivy Bridge / OS X
10.9.5) via the Mavericks launcher + `libavxemu` (AVX2 trap-and-emulate).

## Status: SOLVED (root cause fixed 2026-08-10)

The startup spin — Claude Code **≥ 2.1.183** pegging a core forever at startup in
trusted projects — was **an avxemu 16-bit decode bug**: the decoder dropped the
`66` operand-size prefix on `lzcnt`/`tzcnt`, so the spin's 16-bit `lzcnt cx,di`
was emulated as **32-bit** (result off by +16) and JavaScriptCore's char-search
loop never terminated. **A correctness bug, not slowness** — real CPUs got the
right answer instantly, which is why it was emulation-only. Fixed in avxemu
(branch `avxemu-latest-claude`); the machine runs the latest Claude Code. Full
write-up: **`docs/FINDINGS.md`**.

## What's here now

- **`docs/upstream/mf-find-shadow-sigill/`** — ready to upstream to the
  mavericksforever installer. Native file search shadows `find`/`grep` as
  embedded bfs/ugrep that crash on no-AVX2; the grep-fix hook stripped only
  `grep`, leaving `find` silently SIGILLing. Fix strips both. `REPORT.md` +
  patched `grep-fix.new.sh`.
- **`docs/ugrep-avxemu-segv/`** — open follow-up. Embedded ugrep SIGSEGVs even
  *with* avxemu (a mis-emulation surfacing as a null call), which blocks
  re-enabling native search. Investigation + repro + debug harness, scoped for
  the AVX2-oracle session.
- **`docs/FINDINGS.md`** — the canonical answer to the solved spin.
- **`scripts/`** — pyte/lldb/hook harnesses, launchers, the defended wrapper.

Live status, open follow-ups, and rollback paths live in the session memory.
Investigation history and superseded plans live in git.

## Working assumptions (stable)

- **cwd = this repo.** Harnesses resolve their launcher relative to `scripts/`;
  runtime scratch uses `/tmp`. External siblings by absolute path: avxemu + shim
  source `../Mavericks-Porting-Resources/`; extracted JS bundles
  `../clode/build/2.1.<v>/cli.cjs`.
- **Discipline (this system is bimodal/noisy):** repeat every measurement ≥3×,
  interleave A/B arms and require the control to reproduce, keep runs commensurate
  (same version/binary/login/harness). Hard safety rules: never `cp`-over the live
  `$MF/libavxemu.dylib`; kill only the exact spawned PID (never broad-`pkill`);
  set trust via a throwaway `HOME`, never touch the shared `~/.claude.json`.
