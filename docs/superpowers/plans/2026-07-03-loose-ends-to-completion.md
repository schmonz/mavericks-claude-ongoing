# Loose Ends to Completion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive every loose end from the (now-solved) no-AVX2 startup-spin
investigation to completion: ship the durable defense, file the bug reports,
upstream the reusable fixes, measure the remaining speedup, and land the
knowledge/tooling.

**Architecture:** The bug is solved and documented (`docs/FINDINGS.md`): one
character > U+00FF in a SessionStart hook's `additionalContext` sends Claude
≥2.1.183's embedded Bun-fork JSC into an unbounded loop, but only on no-AVX2
hardware. The machine is usable today via a hand-edited plugin `SKILL.md`; this
plan replaces that fragile state with durable, upstreamed fixes and clears the
backlog. Work is grouped into phases roughly by value; phases are independent
except where noted.

**Tech Stack:** the Mavericks launcher (`/usr/local/bin/claude`, POSIX sh),
`libavxemu` (C11 + x86-64 asm) in `../Mavericks-Porting-Resources/avxemu`, the
`pyte_*` / `lldb_*` / `hook_*` harnesses in `scripts/`, GitHub (`gh`) for
issues/PRs.

**Host shorthand:** `oracle-air` = the AVX2 Haswell box used as the correctness
oracle (ssh-reachable, runs the silicon suite).

---

## Phase 1: Ship the durable defense (HIGH — the machine is only fragilely protected today)

### Task 1: Install the defended launcher on this machine

**Files:**
- Source (ready): `scripts/claude-wrapper-defended`
- Target: `/usr/local/bin/claude` (root-owned)

- [ ] **Step 1: Diff the staged wrapper against what's installed**

Run: `diff /usr/local/bin/claude scripts/claude-wrapper-defended`
Expected: differences (installed lacks the wide-char defense, load-commands grep,
and equals-form args). Review them.

- [ ] **Step 2: Install (needs sudo — run via the `!` prefix in the session)**

```bash
sudo cp scripts/claude-wrapper-defended /usr/local/bin/claude
```

- [ ] **Step 3: Verify it launches and defends**

Run: `/usr/local/bin/claude --version` — expect the version, fast (~5.7s, not 7.9s).
Then confirm the defense is active by checking a no-op launch does not error.

- [ ] **Step 4: Run the canary**

Run: `sh scripts/spin_canary.sh`
Expected: `CANARY OK: idles.` (real plugin payloads idle ≤120s).

- [ ] **Step 5: No commit** (the installed wrapper is outside the repo; the source
  is already committed).

### Task 2: Upstream the wrapper into the installer (Wowfunhappy)

**Files:**
- Patch (ready): `docs/evidence/2026-07-02-recurrence/wrapper-defense.patch`
- Target: `mavericksforever.com/claude/install.sh` (external; not in this repo)

- [ ] **Step 1: Package the change** — the patch carries all three improvements
  (wide-char sanitize+preflight, load-commands-only grep, equals-form `--mcp-config`).
  Confirm it still describes the current installer's emitted wrapper.

- [ ] **Step 2: Send to Wowfunhappy** with a one-paragraph rationale: fresh
  installs and updates should carry the defense by construction so a plugin update
  can't silently re-poison a no-AVX2 machine. Reference `docs/FINDINGS.md`.

- [ ] **Step 3: Record the outcome** in this plan (link to the thread/PR).

---

## Phase 2: Report the bug (HIGH for Anthropic; MED others)

### Task 3: File the Anthropic issue (primary owner)

**Files:**
- Evidence dir: `docs/evidence/2026-07-02-recurrence/` (minimal repro payloads,
  bisect + A/B results, forensics)
- Repro to attach: a settings SessionStart hook `cat`-ing
  `payload_pretty_wide.json` (plugin-free)

- [ ] **Step 1: Draft the issue** (github.com/anthropics/claude-code). Must contain:
  - Symptom: ≥2.1.183 pegs a core indefinitely at startup on no-AVX2 Macs when any
    SessionStart hook emits a char > U+00FF; 2.1.179 fine.
  - Minimal repro: multi-line JSON hook `additionalContext` with one em-dash, no
    plugin required.
  - Bisection table (STUB/HALF/FILL/P714/FILL16/ASCIIFY) and the plugin-off/on A/B.
  - Forensics: phase-A UTF-16 rope loop (`+0x256eaf5`), phase-D cpuid fence churn;
    JSC flag sweep (all 7 arms peg incl. `useJIT=false`) => below codegen, in the
    C++ string layer.
  - Version/hash boundary: 2.1.179=Bun 1.3.14; 183/185/197/198="1.4.0" fork build
    (unreleased upstream; hashes `324c5f012`, `63bb0ca0d`).
  - Ownership evidence: stock Bun 1.3.14 AND today's canary run clean under
    identical emulation (the fork owns it); `oracle-air` native A/B shows NO repro
    on AVX2 (needs the slow-CPU condition).
- [ ] **Step 2: File it** (`gh issue create` or the web form). Save the URL here.

### Task 4: superpowers — ASCII-normalize + the skill contribution

**Files:**
- Ready contribution: `docs/upstream/superpowers-systematic-debugging/` (new
  `reducing-the-trigger.md` + verified `SKILL.md.patch` + submit README)
- The 8-char transliteration diff of `using-superpowers/SKILL.md`

- [ ] **Step 1: File the SKILL fix** (obra/superpowers): normalize
  `skills/using-superpowers/SKILL.md` to ASCII (or sanitize the hook output), with
  the 8-char diff and a note that it hangs Claude on no-AVX2 Macs (link the
  Anthropic issue as the engine-side root cause).
- [ ] **Step 2: Open the systematic-debugging PR** from the staged
  `docs/upstream/` contribution (drop `reducing-the-trigger.md`, `git apply` the
  patch). Save both URLs here.

### Task 5: Bun — route via Anthropic (no direct public issue)

- [ ] **Step 1:** In the Anthropic issue (Task 3), note the engine-level nature so
  their runtime team (who co-maintain the fork) can carry it to Bun. Do NOT file a
  public Bun issue — it would lead with "not reproducible on public code."

---

## Phase 3: Upstream the avxemu fixes (independent of the spin) — MED

### Task 6: PR the general-value avxemu fixes

**Files:**
- Branch: `../Mavericks-Porting-Resources` `fix/avxemu-on-upstream` @ `6c3694a`
- Commits: mulx `dlo==dhi`, jump-table patch safety, reloctest/minspilltest
  far-zone-pool test fixes.

- [ ] **Step 1: Confirm the suite is green on both hosts** (already verified
  2026-07-02): reloctest/minspilltest/nativetest 0/0 on `oracle-air` and the target.
  Re-run `sh build.sh` on `oracle-air` if any doubt.
- [ ] **Step 2: Open the PR(s)** against the canonical avxemu repo. These are
  correctness/portability fixes with no dependence on the spin story:
  - mulx take-the-high-half SIGILL fix (real correctness bug).
  - jump-table-aware `patch_safe` (general relocation improvement).
  - test rel32-range fixes (buffer co-location + `jmp *(%rip)` resume trampoline).
- [ ] **Step 3: Record PR URLs here.**

---

## Phase 4: Measure the remaining speedup and decide — MED

### Task 7: Startup-speedup A/B (avxemu branch vs stock)

**Files:**
- Harness: `scripts/pyte_ttidle.py` + the interleaved-A/B pattern
- Candidate dylib (set aside): `$MF/libavxemu.dylib.custom-20260630`; stock is live.

- [ ] **Step 1: A/B the branch build (fault-storm fix + minspill tier) vs stock**
  on the now-healthy startup (post-transliteration), interleaved, ≥3× each arm,
  metric = CPU-time to idle. Prior rough estimate: 4.4 -> ~3 CPU-s.
- [ ] **Step 2: Decide.** If the win is meaningful and the correctness gates hold
  (`AVXEMU_FORCETRAMP` output==native on target; oracle green), plan promoting the
  branch dylib into the installer. If marginal, leave stock and record the number.
- [ ] **Step 3: Record the result** in `docs/FINDINGS.md` (speedup section).

---

## Phase 5: Land the knowledge and tools — MED/LOW

### Task 8: Put the operational runbook where it's actually read

**Files:**
- Auto-loaded memory: `~/.claude/projects/-Users-schmonz-…/memory/start-here.md`
- (Decision from the RETROSPECTIVE discussion: NO standalone PLAYBOOK.md — it
  would rot unread. Fold the operational essentials into the orientation instead.)

- [ ] **Step 1: Add a short "reproduce & measure safely" runbook** to the
  orientation the memory points at: throwaway HOME + exact-PID teardown +
  never-broad-pkill; fault-stream goes blind post-relocation -> sample the
  execution stream (`scripts/lldb_sampler.py`); static offset = pc − `__TEXT` LOAD
  address, verify vs a known landmark; interleave A/B, control must reproduce;
  hermetic tests need a real-binary gate; validate the treatment arm on the
  known-affected host before trusting a null.
- [ ] **Step 2: Point `start-here` at it** so a fresh agent gets it on load.

### Task 9: Promote the reusable diagnostics to the porting-resources repo

**Files:**
- From `scripts/`: `lldb_sampler.py`, `lldb_phasea_forensic.py`,
  `faultsnap_recur.py`, `hook_ab.sh`, `hook_bisect.sh`, `jsc_flag_sweep.sh`,
  `spin_canary.sh`, `pyte_ttidle.py`.
- To: `../Mavericks-Porting-Resources/` (a `diagnostics/` dir beside avxemu).

- [ ] **Step 1: Copy the generally-reusable tools** with a `README.md` capturing
  the PATTERN (kill-test -> bisect payload -> name the subsystem), not just files.
- [ ] **Step 2: Commit in that repo.** Leave the project-specific harnesses
  (`pyte_screen`, `claude_185_*`) in this repo.

---

## Phase 6: Housekeeping and pre-existing backlog — LOW

### Task 10: Scope the shim to the one binary (IDEAS "option B")

**Files:**
- `docs/archive/IDEAS.md` "Scope the AVX shim…" section (the full write-up)
- Tools present: `$MF/change_dylib`, `$MF/patch_macho`

- [ ] **Step 1:** Bake `libavxemu` as an `LC_LOAD_DYLIB` load command into the
  patched Claude binary instead of `DYLD_INSERT_LIBRARIES`, so the shim stops
  leaking into child `node` (which it crashes). Keep the settings.json `env` scrub
  as the safety net. Re-sign after (ad-hoc, as the other patches do).
- [ ] **Step 2:** Verify a child `node --version` runs clean and the parent still
  emulates. Fold into the launcher/installer update path.

### Task 11: Cleanup and decisions

- [ ] **Plugin re-poison:** once Task 1 (wrapper) is installed, plugin updates are
  auto-handled. Until then, re-run the transliteration after any superpowers update,
  or update 5.1.0 -> latest and re-apply. `scripts/spin_canary.sh` is the check.
- [ ] **Delete `/tmp/*-safety.bundle`** (pre-rewrite git history backups) once the
  history rewrite is confirmed good.
- [ ] **Remove `/tmp/spin_home`** (throwaway HOME).
- [ ] **Decide keep/remove `$MF/libavxemu.dylib.custom-20260630`** after Task 7.
- [ ] **Memory hostname:** decide whether to genericize `oracle-air`'s real
  hostname in the auto-memory files (private, not in any repo).
- [ ] **Git:** the local histories were rewritten (hostname scrub); pushing `main`
  or the avxemu branch will be a force-push (stale remote-tracking refs were dropped).

---

## Self-Review (spec coverage)

Every product from `FOLLOWUPS.md` maps to a task above: ship defense (T1–2), bug
reports (T3–5, incl. the skill PR), avxemu upstreaming (T6), speedup A/B (T7),
knowledge (T8) + tool promotion (T9), shim option B (T10), housekeeping (T11).
RETROSPECTIVE is already written; PLAYBOOK was deliberately dropped in favor of
T8. No task depends on an undefined artifact; all referenced files exist or are
created by an earlier task.
