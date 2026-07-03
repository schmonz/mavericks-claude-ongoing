# Archive — investigation-era documents

The no-AVX2 startup spin is **solved** (see `../FINDINGS.md`). These documents
were the working record and strategy notes *during* the hunt. They are kept for
history and for the dead-ends they rule out, but they are **no longer the source
of truth** — where any of them disagrees with `../FINDINGS.md`, FINDINGS wins.

- **`RULED-OUT.md`** — the chronological investigation log (newest at top). Every
  eliminated hypothesis, every dead end, the attribution corrections, and the
  running verdicts. The richest record of *how* the bug was found; ~1300 lines.
  Internal links that say `docs/RULED-OUT.md` predate the move to `archive/`.
- **`STARTUP-HANG-OPTIONS.md`** — the original BRIEF: constraints, tooling walls,
  the reliable repro. Superseded by `../FINDINGS.md` + the plan.
- **`HEROIC-OPTIONS.md`** — the menu of candidate strategies (Tier 1a/1b/etc.),
  mostly avxemu-centric; superseded once the bug was found to be engine-level.
- **`hot-routine.md`** — Phase-1 measurement work locating the static `__TEXT`
  AVX2 hot site (part of the avxemu trampolining plan, since demoted).
- **`IDEAS.md`** — the investigation-era backlog. All spin-related items are DONE
  or SETTLED; the one still-live item (scope the shim via `LC_LOAD_DYLIB`,
  "option B") is carried forward as Task 10 of the umbrella plan.

For current work see `../FINDINGS.md`, `../RETROSPECTIVE.md`, and
`../superpowers/plans/2026-07-03-loose-ends-to-completion.md`.
