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

- [x] **Step 1: Diff the staged wrapper against what's installed** — DONE 2026-07-04.
  Confirmed the defended wrapper is a clean superset of the installed Jun-24 wrapper:
  only three changes (wide-char defense block, `head -c 1MB` load-commands grep,
  equals-form `--settings`/`--mcp-config`); everything else, incl. `JSC_numberOfGCMarkers=1`
  and the bootstrap/MCP logic, preserved. Backup of the old wrapper saved to
  `/tmp/claude-installed-pre-defense.20260704-110608.bak`.

- [x] **Step 2: Install** — DONE 2026-07-04. `sudo cp` → `/usr/local/bin/claude` now
  7868 bytes, root:wheel, contains the `wide-character hook defense` block.

- [x] **Step 3: Verify it launches and defends** — DONE. `/usr/local/bin/claude --version`
  → `2.1.179 (Claude Code)` in 3.15s (fast path; the daily 179 install resolves via
  `~/.local/bin/claude`). Defended block present in the first 1MB.

- [x] **Step 4: Run the canary** — DONE. `sh scripts/spin_canary.sh` →
  `CANARY OK: idles.` (TTIDLE=9s, maxcpu=2%). Real plugin payloads idle; spin stays dead.

- [x] **Step 5: No commit** — the installed wrapper is outside the repo; source already committed.

### Task 1b: Broaden the wrapper's defense to the WHOLE skills tree (found insufficient 2026-07-04)

**Problem:** the installed wrapper only transliterates `using-superpowers/SKILL.md`
(the file the SessionStart hook reads). But skills load **on demand** mid-session via
the Skill tool, and ~35 of superpowers' files carry wide chars — so starting a
planning session **re-triggered the spin on 2.1.201** even with the wrapper installed
and the startup preflight passing. Root of the miss: sanitize the startup hook only,
not the on-demand skill payloads.

**Files:**
- Tool (ready, committed): `scripts/asciify-wide` (folds every `>U+00FF` char in a
  tree to `<=U+00FF`; readable map + catch-all; idempotent; also installed to `$MF/`).
- Wrapper source to edit: `scripts/claude-wrapper-defended`.

- [x] **Interim:** all 35 superpowers 5.1.0 skill files folded by hand via
  `asciify-wide` (0 wide chars remain); `asciify-wide` copied to `$MF/`. Machine is
  clean *now*, but a plugin update re-poisons it.
- [ ] **Step 1:** Rewrite the wrapper's defense block to, for every ENABLED plugin,
  run `asciify-wide -r "$PROOT/skills"` (fold the whole tree) instead of the single
  `sed` on `using-superpowers/SKILL.md`. Keep the SessionStart-hook preflight as the
  secondary net. Call `$MF/asciify-wide` (stable path, survives repo moves).
- [ ] **Step 2:** `sudo cp` the rewritten wrapper to `/usr/local/bin/claude`; back up
  the current one first.
- [ ] **Step 3: Verify** the canary (`spin_canary.sh`) AND an **on-demand** case:
  launch, invoke a skill whose SKILL.md had wide chars, confirm no spin. Re-poison one
  skill file, relaunch, confirm the wrapper re-folds it.

### Task 2: Upstream the wrapper into the installer (Wowfunhappy)

**Files:**
- Patch (ready): `docs/evidence/2026-07-02-recurrence/wrapper-defense.patch`
- Target: `mavericksforever.com/claude/install.sh` (external; not in this repo)

- [ ] **Step 1: Package the change** — ship the **broadened** wrapper (Task 1b) plus
  **`asciify-wide`** (the installer should drop it into `$MF/`), the load-commands-only
  grep, and the equals-form `--mcp-config`. The old `wrapper-defense.patch` predates
  the whole-tree fold — regenerate it against the Task-1b wrapper first.

- [ ] **Step 2: Send to Wowfunhappy** with a one-paragraph rationale: fresh
  installs and updates should carry the defense by construction so a plugin update
  can't silently re-poison a no-AVX2 machine. Reference `docs/FINDINGS.md`.

- [ ] **Step 3: Record the outcome** in this plan (link to the thread/PR).

---

## Phase 2: Report the bug (HIGH for Anthropic; MED others)

### Task 3: File the Anthropic issue (primary owner)

**Files:**
- **Written, submit-ready:** `docs/upstream/anthropic-jsc-16bit-spin/BUG-REPORT.md`
  (instruction-level root cause + plugin-free minimal repro). This is the issue body.
- Evidence dir: `docs/evidence/2026-07-02-recurrence/` (minimal repro payloads,
  bisect + A/B results, forensics)
- Repro to attach: a settings SessionStart hook `cat`-ing
  `payload_pretty_wide.json` (plugin-free)

- [x] **Step 1: Draft the issue** — DONE 2026-07-04, `BUG-REPORT.md`. It contains the
  symptom, the plugin-free minimal repro, the version/hash boundary, the ownership
  evidence, AND the **instruction-level root cause nailed this session**: the wide
  char forces JSC's 16-bit string; the app line-splits it (`indexOf('\n')`) and
  **re-searches a ~3472-char UTF-16 rope repeatedly**; the only trapping instruction
  is **`lzcnt cx,di` at `fn44058+0x2fe` (`+0x256e58e`)** — BMI1/ABM, absent on Ivy
  Bridge. ~85.8M emulated `lzcnt` × ~20µs spill ≈ 28 min ("never idles"); native
  `lzcnt` ≈ 0.09s (the work is finite, not unbounded). Extracted live by reading the
  emulator thunk's resume pointer. (Supersedes the older `+0x256eaf5` framing.)
- [ ] **Step 1b: Add the bundled-tool DYLD note** to the same issue (see Task 3b) —
  a second, independent no-AVX2 defect worth reporting together.
- [ ] **Step 2: File it** (`gh issue create` or the web form). Save the URL here.

### Task 3b: Report the bundled-tool DYLD scrub (`find`/`grep`/`rg` crash on no-AVX2)

**Problem it documents (found 2026-07-04):** Claude Code shadows `find`→bfs,
`grep`→ugrep and spawns `rg` (Grep/Glob) as **self-re-execs of its own AVX2 binary**
(`argv0:"rg"` etc.; no separate vendored binaries). It also blanks `DYLD_*` for its
Bash-tool subprocesses. On a no-AVX2 host those applets then run the AVX2 binary with
**no emulator loaded → SIGILL** (confirmed: `find`→exit 132). `rg`/`ugrep` survive via
runtime CPU detection; `bfs` does not.

- [ ] **Step 1:** Fold a short section into the Anthropic issue: preserve `DYLD_*`
  when re-exec'ing the own binary as an applet (or honor a `USE_BUILTIN_*=0`-style
  toggle so the shell shadows fall back to system `find`/`grep`). The robust framing:
  "when you re-exec your own executable, don't strip the environment that makes it
  runnable."
- [ ] **Step 2:** Cross-link to the *local* fix (Task 10, avxemu self-gate), which
  makes the applets work by construction on our machines regardless of upstream.

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

**Branches in `../Mavericks-Porting-Resources` (each maps to a problem it fixed):**
- `fix/avxemu-on-upstream` @ `6c3694a` (38 ahead): **mulx `dlo==dhi` SIGILL** (avxemu
  crashed the real binary), **jump-table patch-safety** (the fault storm, 72% of busy
  samples), **reloctest/minspilltest far-zone-pool** test false-failures, plus the
  minspill/native tier (speedup — Task 7) and the FAULTHIST/FAULTSNAP/OPHIST diagnostics.
- `fix/lde-zcnt-overflow-and-gather` (3 ahead): **lde_rd_zcnt worklist overflow +
  chain SIGILL-loop hang** (LDE-scanner hang). Confirm not already subsumed by the
  above before PR'ing.
- `grow-macho-header` (2 ahead): **`change_dylib -grow` + `macho_grow.h`** — patch
  tightly-packed newer binaries (16-byte header pad) via the `__PAGEZERO` image-base
  trick.
- `feat/change-dylib-add` (worktree, uncommitted): **`change_dylib -add`** (append an
  `LC_LOAD_DYLIB`). General-value tool; its original use case (bake avxemu) is dead
  (Task 10) — keep the tool, commit it, note the caveat.

- [ ] **Step 0 (BLOCKER for `-grow`): fix `mg_grow_header` runtime corruption.** We
  found a `-grow`'d 2.1.179 binary **heap-corrupts at runtime** (`incorrect checksum
  for freed object`) even via the known-good DYLD path — so `grow-macho-header` is NOT
  safe to ship for tight-pad binaries yet. Diagnose (likely a file-offset field the
  image-base shift misses) and add a runtime gate to the test before PR'ing `-grow`.
- [ ] **Step 1: Confirm the avxemu suite is green on both hosts** (verified 2026-07-02):
  reloctest/minspilltest/nativetest 0/0 on `oracle-air` and the target. Re-run
  `sh build.sh` on `oracle-air` if any doubt.
- [ ] **Step 2: Open the PR(s)** against the canonical repo, grouped by concern:
  - avxemu correctness: mulx high-half SIGILL, jump-table-aware `patch_safe`, lde_zcnt
    overflow/hang, test rel32-range fixes.
  - Mach-O tooling: `change_dylib -grow`/`macho_grow.h` (after Step 0), `-add`,
    `-delete`/`-reexport`.
- [ ] **Step 3: Record PR URLs here.**

---

## Phase 4: Measure the remaining speedup and decide — MED

### Task 7: Startup-speedup A/B (avxemu branch vs stock)

**Files:**
- Harness: `scripts/pyte_ttidle.py` + the interleaved-A/B pattern
- Candidate dylib (set aside): `$MF/libavxemu.dylib.custom-20260630`; stock is live.

> **Settled 2026-07-04:** the minspill/native tier is a **speedup, not a spin fix** —
> re-confirmed by injecting the branch dylib with `AVXEMU_MINSPILL=1` into the poisoned
> repro: still `TTIDLE=none` (100% CPU). The spin is finite-but-huge emulated `lzcnt`
> work; faster per-op emulation doesn't cross the idle threshold. So this task is a
> pure "is the general startup speedup worth shipping" decision — NOT part of the spin
> remedy (that's transliteration / the launcher / the engine fix).

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

### Task 10: Make avxemu safe for children AND working for self-exec applets

**Promoted from LOW → this is the one genuinely-open FIX.** Two-sided problem: avxemu's
constructor does load-time code-patching + signal interposition, which **crashes child
`node`/`bun`** (heap corruption — `malloc: incorrect checksum for freed object`,
reproduced 2026-07-04). We currently scrub `DYLD_*` for children (settings.json `env`)
to stop that — but that **breaks the bundled applets** (`find`→bfs, `grep`→ugrep, `rg`),
which are self-re-execs of the AVX2 claude binary and SIGILL with no shim (Task 3b).

**PROVEN DEAD 2026-07-04 — the old "option B" (LC_LOAD_DYLIB instead of DYLD_INSERT):**
Baking avxemu as a load command makes bfs/ugrep/rg work with no env, but the **main Bun
app then fails** (`FATAL: Could not allocate gigacage memory` / spins). avxemu must be
loaded EARLY via `DYLD_INSERT_LIBRARIES` for its interposition to win; a late load
command doesn't, and a `noop.dylib` in DYLD_INSERT doesn't substitute. So we **cannot
drop DYLD_INSERT for the main app.** (Also found: `change_dylib -add` works and
`mg_grow_header` corrupts grown binaries — see Task 6.)

**Real fix = avxemu SELF-GATE (keeps the only load path that works):**
- [ ] **Step 1:** Gate avxemu's `__mod_init_func`: do the invasive patch/interpose
  **only if the main executable opted in by linking avxemu** (walk image-0's
  `LC_LOAD_DYLIB`s for its own install name); otherwise return early and stay inert
  (like a no-op dylib). General, not Claude-specific — answers "what if another program
  wants avxemu": it links it and the gate lets it through.
- [ ] **Step 2:** Add the opt-in marker `LC_LOAD_DYLIB` to the claude binary in the
  launcher's existing patch pass (`change_dylib -add`) — marker only; the functional
  early load stays `DYLD_INSERT` (dyld dedups). `node`/`python` don't link it → inert.
- [ ] **Step 3:** Delete the settings.json `DYLD_INSERT_LIBRARIES=""` scrub. Verify:
  `node --version` clean; `find`/`grep`/`rg` work; main app + spin behavior unchanged.
- [ ] **Fallback if the self-gate gets ugly:** make avxemu **passive** — a chained
  SIGILL handler that emulates lazily on fault, no eager patch/interpose. Safe to load
  anywhere (no gate needed), but a deeper avxemu-core change.

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
- [ ] **This session's scratch (2026-07-04/05):** remove `/tmp/spinfix`,
  `/tmp/avxemu_test`, `/tmp/spinfix_home`, `/tmp/mgadd`/`/tmp/mgx`/`/tmp/mgtest` if
  present. **Keep** the fetched `~/.local/share/claude/versions/2.1.185` — it's the
  bug-report repro binary (with the mapped offsets).
- [ ] **`feat/change-dylib-add` worktree** at `~/Documents/code/trees/mpr-add-dylib`:
  commit the `-add` change (with the "bake-avxemu use case is dead" caveat) or discard,
  then `git worktree remove` it.
- [ ] **`docs/FINDINGS.md`:** update the root-cause section to the instruction level
  (`lzcnt cx,di` at `fn44058+0x2fe`, finite emulated work) — supersede the older
  `+0x256eaf5` rope framing. Point it at `docs/upstream/anthropic-jsc-16bit-spin/`.

---

## Self-Review (spec coverage)

Coverage: ship defense (T1 done; **T1b broaden to whole skills tree — open**; T2
Wowfunhappy incl. `asciify-wide`), bug reports (T3 Anthropic incl. the nailed
instruction-level root cause; **T3b bundled-tool DYLD/`find`-`grep`-`rg` finding**;
T4 superpowers; T5 Bun-via-Anthropic), avxemu + Mach-O-tooling upstreaming (T6, incl.
`-grow`/`macho_grow`/`-add` and the **`mg_grow` corruption blocker**), speedup A/B
(T7 — settled as speedup-only, not a spin fix), knowledge (T8) + tool promotion (T9),
**T10 reworked: LC_LOAD_DYLIB proven dead → avxemu self-gate** (the one open fix),
housekeeping (T11, incl. this session's scratch + FINDINGS instruction-level update).

**Reconciled 2026-07-04/05** against the full session: added T1b, T3b; corrected T6
(Mach-O tooling + `mg_grow` bug), T7 (settled), T10 (dead approach replaced). Every
fix we've made now maps to a task with the problem it solved noted inline.

## What needs YOU vs what I can prep

- **Needs your account/hands:** filing the Anthropic issue (T3/3b), the superpowers
  PRs (T4), sending the Wowfunhappy package (T2), opening the avxemu/Mach-O PRs (T6),
  the `sudo` reinstall (T1b Step 2). I make each submit-ready.
- **I can do solo now:** T1b wrapper rewrite, T6 Step 0 (`mg_grow` fix) + green-suite
  check, T10 self-gate implementation, FINDINGS update, worktree/scratch cleanup,
  and drafting every issue/PR body.
