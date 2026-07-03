# mavericks-claude-ongoing

Making upstream **Claude Code** usable on a **no-AVX2 Mac** (Ivy Bridge / OS X
10.9.5) via the Mavericks launcher + `libavxemu` (AVX2 trap-and-emulate).

## Status: SOLVED (2026-07-02)

Claude Code **≥ 2.1.183** pegged a core indefinitely at startup in *trusted*
projects on this machine class. **Root cause:** one character above U+00FF in a
SessionStart hook's payload (the superpowers plugin's em-dashes) forces
JavaScriptCore's 16-bit string path, which loops forever under AVX2 emulation on
the slow CPU. **Fix:** transliterate ~6 punctuation characters (or install the
defended launcher, which does it automatically). 2.1.185/197/198 now idle in ~9s.

Full write-up: **`docs/FINDINGS.md`**.

## Where to read

1. **`docs/FINDINGS.md`** — the answer: bug, root cause, fix, defenses, scope,
   ownership, evidence index. **Start here.**
2. **`docs/superpowers/plans/2026-07-03-loose-ends-to-completion.md`** — the
   umbrella plan: every remaining loose end (ship the defense, file the reports,
   upstream the fixes, measure the speedup) as executable tasks. (`FOLLOWUPS.md`
   at the root is a thin pointer to this.)
3. **`docs/RETROSPECTIVE.md`** — how we could have found it in a day (the signals
   we underweighted).
4. **`docs/upstream/`** — a contribution back to superpowers'
   `systematic-debugging` skill, distilled from the retrospective.
5. **`docs/archive/`** — the investigation-era record: `RULED-OUT.md` (the
   chronological log + every dead end), the old brief, and superseded strategy
   notes. History, not source of truth.

## Layout

```
docs/FINDINGS.md          the solved answer (source of truth)
docs/RETROSPECTIVE.md     lessons: how to have found it faster
docs/superpowers/         plans (the umbrella plan is 2026-07-03-…) + historical specs/plans
docs/upstream/            staged superpowers skill contribution
docs/archive/             investigation-era docs (RULED-OUT log, brief, strategy notes)
docs/evidence/            captured repros, bisections, forensics
scripts/                  pyte_*/lldb_*/hook_* harnesses + claude_* launchers + the defended wrapper
```

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
