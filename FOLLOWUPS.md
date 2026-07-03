# FOLLOWUPS — no-AVX2 spin project backlog

Outstanding products and loose ends after root-causing the no-AVX2 startup spin
(2026-07-02). The bug is SOLVED and characterized (see `docs/RULED-OUT.md` top):
one char > U+00FF in a SessionStart hook's `additionalContext` sends Claude
≥2.1.183's embedded Bun-fork JSC into an unbounded loop, but ONLY on no-AVX2
hardware under emulation. Machine is currently usable (on 2.1.198, stock avxemu,
real superpowers 5.1.0 `SKILL.md` transliterated to ASCII).

Host shorthand below: **oracle-air** = the AVX2 Haswell box used as the
correctness oracle (`ssh`-reachable; runs the `bmi_exec`-vs-silicon suite).

---

## A. Ship the defense (durably protect the machine) — HIGH

- [ ] **Install the defended launcher.** Current `/usr/local/bin/claude` has NO
  defense; today's protection is just the hand-edited 5.1.0 `SKILL.md`, which the
  next plugin update WIPES (fresh install drops a pristine wide-char `SKILL.md`).
  `sudo cp scripts/claude-wrapper-defended /usr/local/bin/claude`. Adds: wide-char
  hook sanitize + preflight refusal (gated on the no-AVX2 branch, bypass
  `CLAUDE_MF_ALLOW_WIDE_HOOKS=1`), the load-commands-only grep speedup
  (~2.5s/launch), and the `--mcp-config` equals-form arg fix. Measured 7.9s→5.7s.
- [ ] **Upstream it into the installer** (`mavericksforever.com/claude/install.sh`,
  Wowfunhappy) so fresh installs + updates carry the defense by construction, not
  a per-machine hand-copy. Patch: `docs/evidence/2026-07-02-recurrence/wrapper-defense.patch`.
- [ ] **Post-update guard:** run `scripts/spin_canary.sh` after any claude/plugin
  update (verifies real payloads idle ≤120s). Consider wiring it into the launcher
  or a login check.

## B. Bug reports — HIGH (Anthropic), MED (others)

- [ ] **Anthropic (primary — github.com/anthropics/claude-code).** "≥2.1.183 pegs
  CPU indefinitely at startup on no-AVX2 Macs when any SessionStart hook emits a
  char > U+00FF; 2.1.179 fine. Your embedded Bun fork's 1.4.0 line owns it."
  Attach: plugin-free minimal repro (a settings SessionStart hook `cat`-ing a
  pretty-printed JSON with one em-dash — `docs/evidence/2026-07-02-recurrence/`),
  bisection table, phase-A forensics (UTF-16 rope loop) + phase-D (cpuid fence
  churn), JSC flag sweep (all 7 arms peg incl. `useJIT=false`), version/hash
  boundary (179=Bun 1.3.14; 183/185/197/198=fork "1.4.0", unreleased upstream),
  and the oracle-air native A/B showing NO repro on AVX2.
- [ ] **superpowers (obra/superpowers) — defense-in-depth.** ASCII-normalize
  `skills/using-superpowers/SKILL.md` (or sanitize the hook output). Include the
  8-char transliteration diff (em-dash/en-dash/arrow/not-equals). Frame: the plugin
  is the innocent messenger; this hardens old-Mac users until the engine is fixed.
- [ ] **Bun — via Anthropic**, not a direct public issue (their engineers
  co-maintain the fork; a public report leads with "not reproducible on public
  code" — we verified stock 1.3.14 AND today's canary run clean under identical
  emulation).

## C. Upstream the avxemu fixes (independent of the spin) — MED

Branch `fix/avxemu-on-upstream` @ `6c3694a`. All general-value:
- [ ] **mulx `dlo==dhi` high-half fix** — a real SIGILL-class correctness bug
  (the take-the-high-half idiom kept the LOW half).
- [ ] **Jump-table-aware patch safety** — resolves bounded LLVM switch dispatch
  instead of blanket-declining.
- [ ] **reloctest/minspilltest far-zone-pool fixes** — the tests failed on modern
  macOS because the RWX pool lands >2GB from their code (jmp rel32 range); fixed
  test-side (buffer co-location + `jmp *(%rip)` resume trampoline). Now 0/0 on both
  oracle-air (macOS 15) and the 10.9 target.

## D. Measure the emulation startup speedup — MED

- [ ] A/B the avxemu branch (fault-storm fix + minspill tier) vs stock on the
  now-healthy startup, using `scripts/pyte_ttidle.py` / the interleaved-A/B pattern
  (≥3× each arm). Rough prior estimate: 4.4→~3 CPU-s. If it wins meaningfully,
  promote the branch dylib into the installer (the custom build is set aside at
  `$MF/libavxemu.dylib.custom-20260630`; stock is currently live).

## E. Durable knowledge — MED

- [ ] **`docs/RETROSPECTIVE.md`** — "how we could have found it in a day."
  Signals we underweighted: trust-as-evidence (not lab hygiene); environment
  bisection BEFORE mechanism analysis; build repros empty-up not cloned-down;
  obey the work-volume-vs-op-cost arithmetic (freeze op-optimization when it says
  "more work, not slower work"); profile DATA not just code ("which bytes" beat
  "which function"); check provenance of black-box components (5 min, reframed
  ownership); distrust untimestamped instruments, unresolved anonymous frames, and
  unverified offsets; "fails environmentally, ignore" earned no free pass (it was
  the rel32 test bug in C).
- [ ] **`docs/PLAYBOOK.md`** — the operational rules: throwaway HOME + exact-PID
  teardown + never broad-pkill; fault-stream diagnostics go blind once relocation
  succeeds → sample the EXECUTION stream (`scripts/lldb_sampler.py`); static offset
  = pc − `__TEXT` LOAD address, verify against a known landmark first; interleave
  A/B arms and require the control to peg; validate the treatment arm engages the
  mechanism on the KNOWN-affected system before trusting a null on the question
  system; hermetic tests need a real-binary gate.

## F. Promote the tooling — LOW/MED

- [ ] Move the reusable diagnostics next to avxemu in Mavericks-Porting-Resources
  with a README of the PATTERN (kill-test → bisect payload → name the subsystem):
  `lldb_sampler.py`, `lldb_phasea_forensic.py`, `faultsnap_recur.py`, `hook_ab.sh`,
  `hook_bisect.sh`, `jsc_flag_sweep.sh`, `spin_canary.sh`, `pyte_ttidle.py`.

## G. Optional deepening — LOW

- [ ] Pin the exact looping JSC routine (WTF::StringImpl / rope resolver) via the
  deep-bt evidence + Bun 1.4.0 sources — strengthens the Anthropic/Bun report.
- [ ] Close the CLAUDE.md caveat: a jumbo (3KB+) non-ASCII `CLAUDE.md` with the
  plugin off (tested innocent only at ~170B; the hook path triggered at ~3KB).
- [ ] Write up the story ("two weeks of suspects, and it was an em-dash") — a
  genuinely publishable debugging narrative.

## H. Housekeeping — LOW

- [ ] Update the real superpowers plugin (5.1.0 → latest; 6.1.0 already exists in
  the throwaway HOME) and re-apply the transliteration — OR rely on the wrapper
  defense (A) once installed, which handles it automatically.
- [ ] Delete the `/tmp/*-safety.bundle` history backups once the git-history
  rewrite is confirmed good (they still contain the old hostname string).
- [ ] Remove throwaway `/tmp/spin_home`.
- [ ] Decide keep/remove `$MF/libavxemu.dylib.custom-20260630` after (D).
- [ ] Auto-memory files (`~/.claude/projects/.../memory/`) still reference
  oracle-air's real hostname functionally — decide whether to genericize (private,
  not in any repo).
- [ ] Git history was rewritten locally (hostname scrub); pushing `main` would be a
  force-push (the stale `origin/main` remote-tracking ref was dropped).

---

**See also `docs/IDEAS.md`** for the older, spin-independent backlog (e.g. baking
`libavxemu` as an `LC_LOAD_DYLIB` load command so the shim stops leaking into child
`node` processes — "option B").
