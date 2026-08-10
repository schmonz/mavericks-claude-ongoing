# Attempt: run the latest Claude Code on this no-AVX2 Mavericks machine

**Started:** 2026-08-10. **Goal:** move off the pinned-safe 2.1.179 to the current
release *deliberately and reversibly*, applying everything learned in the (solved)
no-AVX2 spin investigation so we do not repeat any dead end.

This is the running experiment log. Every step records: what we did, the expected
result from prior findings, and the actual result. Nothing live changes until the
isolated (throwaway-HOME) test is green. Source-of-truth for the physics:
`docs/upstream/anthropic-jsc-16bit-spin/BUG-REPORT.md` and
`docs/superpowers/plans/2026-07-03-loose-ends-to-completion.md`.

---

## Baseline (established 2026-08-10, with evidence)

| Fact | Value | How verified |
|---|---|---|
| Live launcher | `/usr/local/bin/claude` (root:wheel, 7868 B, Jul 4) | `ls -l` |
| Version in use | **2.1.179** (pre-bug, Bun 1.3.14) | `~/.local/bin/claude` symlink target |
| Installed versions | 2.1.179 (active), 2.1.185, 2.1.201, **2.1.220 (new)** | `ls versions/` |
| Installed wrapper defense | **OLD** — folds only `using-superpowers/SKILL.md` + preflights hooks | `grep` of `/usr/local/bin/claude` |
| Task 1b (whole-tree fold) | **NOT applied** in installed wrapper | same |
| Live plugin tree wide chars | **42 files** incl. `modernmavericks-conventions/SKILL.md` (on-demand skill) and `superpowers/.../hooks/session-start` | `asciify-wide --check -r ~/.claude/plugins/cache` |
| Latest stable / bleeding | **2.1.220** / 2.1.226 | `curl downloads.claude.ai/.../stable` |
| 2.1.220 download | installed + sha256-verified `dca7be0a…70ce2f3` | `fetch-version.sh 2.1.220` |

**Why 2.1.179 is currently safe:** its engine (Bun 1.3.14) predates the JSC 16-bit
regression, so the 42 live wide-char files are inert. They become live spin triggers
the instant we run any engine >= 2.1.183.

## The two known failure modes for newer versions (from findings)

1. **The spin.** One char > U+00FF in *any* string the engine ingests — a
   SessionStart hook's `additionalContext` OR an on-demand-loaded skill file — flips
   JSC to its 16-bit string path; the line-split re-scans a UTF-16 rope, whose SIMD
   search hits `lzcnt` (BMI1/ABM, absent on Ivy Bridge) → trap-and-emulate → ~28 min
   of finite-but-huge work = "hangs forever". **Mitigation:** fold the whole enabled
   plugin tree to <= U+00FF (`asciify-wide -r`) AND broaden the launcher to do it
   automatically (Task 1b), keeping the preflight-refuse as backstop.
2. **Bundled-tool SIGILL.** The binary shadows `find`→bfs / `grep`→ugrep and spawns
   `rg` as self-re-execs of its own AVX2 binary; with `DYLD_*` scrubbed those run with
   no emulator → SIGILL on no-AVX2. Mitigated today by `USE_BUILTIN_RIPGREP=0` + the
   settings.json grep-fix hook. **Must re-verify under 2.1.220.**

Plus a version-specific risk: the launcher patches the Mach-O in place
(`patch_macho` + `add_version_min` + `change_dylib`). Newer builds have very tight
header padding; `add_version_min` may need header room. **Must verify the patch
applies cleanly to 2.1.220** (distinct from the known `mg_grow` corruption, which is
`-grow` only; the launcher uses `-change`).

---

## Plan (each step gated on the previous; nothing live until Step 5 is reached)

- [x] **0. Baseline + download 2.1.220** (non-destructive). Done above.
- [ ] **1. Broaden the launcher (Task 1b)** in `scripts/claude-wrapper-defended`:
  fold the whole enabled-plugin tree via `asciify-wide -r` before the preflight.
  Repo edit only; live launcher untouched.
- [ ] **2. Isolated test of 2.1.220** in a throwaway HOME via the broadened wrapper:
  - measure TTIDLE (spin check) on the real (folded) plugin payloads — expect it idles;
  - confirm the Mach-O patch applies cleanly to 2.1.220;
  - verify `find` / `grep` / `rg` do not SIGILL;
  - **control:** confirm a deliberately re-poisoned skill still hangs (canary valid).
- [ ] **3. Decision checkpoint with the user** — only proceed to live changes if Step 2
  is green. Record the go/no-go here.
- [ ] **4. Install broadened wrapper** (`sudo cp`, back up current first).
- [ ] **5. Fold the live plugin tree** (`asciify-wide -r`; .wide-bak backups kept).
- [ ] **6. Switch symlink** `~/.local/bin/claude` → 2.1.220. Keep 2.1.179 as a
  one-command rollback (`ln -sf …/versions/2.1.179 ~/.local/bin/claude`).
- [ ] **7. Verify live:** fresh session idles; invoke an on-demand skill whose SKILL.md
  had wide chars → no spin. Re-run `spin_canary.sh`.

## Upstream launcher re-fetched (2026-08-10, at user's prompt)

Fetched `mavericksforever.com/claude/install.sh` (15198 B, sha256 `08cef8e2…2d3b9de9`).
It **has diverged** from our July wrapper — two-way:

**Upstream now has (adopt):**
- `CLAUDE_CODE_USE_NATIVE_FILE_SEARCH=0` — the *proper* fix for the bundled-tool
  SIGILL (failure mode #2): stops the `grep`/`find` shadow being written at all, so
  they stay the real `/usr/bin` tools. Supersedes our old DYLD-scrub approach.
- Expanded grep-fix hook: also restores the `libS/libI/libc++` aliases mid-session.

**Upstream still lacks (re-apply our deltas):**
- The wide-char defense (never upstreamed — Task 2 still open).
- `head -c 1MB` patch-detection speedup (upstream greps the full 254 MB binary).
- Equals-form `--settings=`/`--mcp-config=` flags (space-form swallows positional args).

**Decision:** merge — upstream base + our 3 deltas + the *broadened* fold (whole
plugin cache, not just one SKILL.md). modernmavericks confirms the need: it has an
on-demand `SKILL.md` with wide chars but **no** session-start hook and isn't in the
enabled list, so any per-hook/enabled-gated loop misses it. The fold must run over
the whole cache unconditionally.

## Results log

- 2026-08-10: Baseline captured; 2.1.220 fetched + verified.
- 2026-08-10: Re-fetched upstream installer at user's prompt — found it diverged
  (adds `CLAUDE_CODE_USE_NATIVE_FILE_SEARCH=0` + better grep-fix hook; still no
  wide-char defense). Merging rather than diverging.
- 2026-08-10: **SMOKE on 2.1.220 revealed a NEW wall (not the spin):** dyld
  `Symbol not found: ___ulock_wait`. The Mach-O patch applied fine; the binary
  won't *link* on 10.9. (`try_latest.sh smoke`'s "OK" was a false positive — it
  matched "2.1.220" in the error path.)
- 2026-08-10: **Root-caused via symbol diff.** Every version imports
  `___ulock_wait2` + `___ulock_wake` (our `libSystemWrapper.dylib` already shims
  both; the 10.9 kernel has no ulock at all). 2.1.220 additionally imports
  `___ulock_wait` — the *only* new symbol absent on 10.9 (the other 4 new imports,
  `_clock`/`_mach_thread_self`/`_thread_info`/`_vm_inherit`, all exist in 10.9's
  libSystem and forward via the wrapper's `LC_REEXPORT_DYLIB`). So a single
  `__ulock_wait` shim clears the wall for 2.1.220.
- 2026-08-10: **Checked upstream (user's prompt: "maybe we just need bcdb4be?").**
  Fetched Wowfunhappy master over HTTPS (ssh key unavailable). `bcdb4be` = "Fix
  newest Claude Code + Reorganize" (2026-07-18): deletes `modern_api_polyfills.c`
  (1454 lines), splits into `mavericks-legacy-support/src/*.c` force-loaded as a
  static lib, adds `-framework CoreServices`, and adds shims for even-newer builds
  (`kevent64_shim.c`, `dlopen_interpose.c`, `renameatx_np.c`, …). Its
  `src/ulock.c` `__ulock_wait` is **identical** to the forwarder derived here, and
  its comment confirms **the import appeared in Claude Code 2.1.214**. For 2.1.220
  the one forwarder is provably sufficient (symbol diff); the rest of the reorg
  targets later versions.
- 2026-08-10: **User chose FULL UPSTREAM SYNC.** Divergence assessed: merge-base
  `37f8434`; our side = 32 commits, all under `avxemu/`; upstream side = 3 commits
  (`bcdb4be` reorg, `2bd9861` notify stub, `4333950` OpenSSL SecKey login fix).
  **Conflict surface EMPTY.** Merged `wf-https/master` into new branch
  `sync/upstream-newest-claude` (merge `c247ef2`), conflict-free, avxemu work
  intact. `mavericks-legacy-support/src/ulock.c:79` now defines `__ulock_wait`.
- 2026-08-10: Built `mavericks-legacy-support` static lib via its self-contained
  `make` (48 src/*.c, targets 10.9) → `lib/libMavericksLegacySupport.a` exporting
  `___ulock_wait`. Then a TARGETED rebuild of just `libSystemWrapper.dylib`
  (upstream's exact clang line: reexport libSystem.B + force_load the static lib +
  CF/Security/CoreVideo/CoreGraphics/CoreServices/objc) → `/tmp/libSystemWrapper.new.dylib`.
- 2026-08-10: **Regression audit + empirical load test.** `nm -g` diff looked
  alarming (old kitchen-sink wrapper "exported" many CG/CV/libc++ symbols the new
  modular one doesn't) but every one is either not imported-from-libS by the
  binaries or re-exported from real `libSystem.B` (which even provides `___exp10`
  natively). Ground truth: hardlinked the patched 2.1.179 and 2.1.220 binaries,
  put the new wrapper beside them as `libS.dylib`, ran `--version`:
  **both print their version and run** → 2.1.220 wall cleared, 2.1.179 not
  regressed. Wrapper validated.
- 2026-08-10: Installed the validated wrapper to `$MF/libSystemWrapper.dylib`
  (backup `…dylib.pre-ulock.20260810`); live `/usr/local/bin/claude --version` →
  `2.1.179` still fine.
- 2026-08-10: **Spin test, take 1 (FLAWED CONTROL).** `try_latest.sh` arm A
  (defended 2.1.220, real folded plugins) idled (TTIDLE=15). But arm B (poison a
  plugin SKILL.md + defense off) idled too — AND so did known-susceptible 2.1.201
  with the same mechanism. The plugin-file poison did NOT reproduce the spin →
  control invalid, conclusions withheld. (Also: launching 2.1.220 **pruned**
  2.1.201 from `versions/`, and running the wrapper under a throwaway HOME left the
  shared `versions/*.dylib` aliases pointing into `/tmp` — both since healed.)
- 2026-08-10: **Spin test, take 2 (FAITHFUL).** New `spin_repro.sh` uses the
  bug-report's plugin-free minimal repro (a user-settings SessionStart hook that
  `cat`s `payload_pretty_{wide,ascii}.json`), defense off, throwaway HOME.
  Results:
  - `2.1.185/wide` → **SPUN** (TTIDLE=none, 89s @ 104%) — harness reproduces on a
    known-susceptible build. Control valid.
  - `2.1.220/wide` → **SPUN** (TTIDLE=none, 89.6s @ 101%) — **the engine bug is
    NOT fixed in the latest.**
  - `2.1.220/ascii` (identical payload minus the one wide char) → idled
    (TTIDLE=15) — the wide char is the sole trigger.
  ⇒ arm A's defended-idle IS meaningful: 2.1.220 needs the fold, and the fold
  works. NB: the defense targets the real vector (plugin skill/hook files in the
  cache); it does NOT sanitize an arbitrary user-settings hook payload (that repro
  is only a clean engine trigger). Real-world usage is covered.

## Verdict so far

2.1.220 is **runnable on this no-AVX2 machine** with BOTH fixes in place:
1. **Link wall** (`__ulock_wait`, new since 2.1.214) → fixed by the upstream-synced
   `libSystemWrapper.dylib` (installed, validated, 2.1.179 not regressed).
2. **Spin** (still present in 2.1.220) → defended by the broadened launcher's
   whole-plugin-cache fold (validated: defended idles, undefended spins).

## LIVE CUTOVER — DONE 2026-08-10 (user approved)

- [x] Backed up 2.1.179 out-of-band → `$MF/rollback/2.1.179` (pruning-proof).
- [x] Installed broadened launcher to `/usr/local/bin/claude` (old one saved to
  `/usr/local/bin/claude.pre-broaden.20260810`). New launcher = upstream base +
  `CLAUDE_CODE_USE_NATIVE_FILE_SEARCH=0` + whole-plugin-cache fold + our head-c /
  equals-form deltas.
- [x] Folded the live plugin cache (41 files) → `--check` reports 0 wide remaining.
- [x] Switched `~/.local/bin/claude` → `versions/2.1.220`.
- [x] Verified: `claude --version` → **2.1.220** in 5.3s; **`spin_canary.sh` →
  CANARY OK: idles** (TTIDLE=15) on the live 2.1.220 with real folded payloads.
- Rollback (one command): `ln -sf $HOME/.local/share/claude/versions/2.1.179 \
  $HOME/.local/bin/claude` (restore from `$MF/rollback/2.1.179` first if pruned).

**The machine now runs the latest Claude Code (2.1.220).**

## ✗ REGRESSION FOUND ON RESUME — ROLLED BACK 2026-08-10 (same day)

The go-live verification only tested **fresh** launches (`--version`, canary). The user
quit and ran **`claude -c`** (continue) on 2.1.220 → **hung at 100% CPU** (PID 8837,
pegged ~4.5 min before I found it).

**Root cause — a THIRD wide-char vector the defense never covered: the conversation
transcript.** `claude -c` loads the prior session's transcript
(`~/.claude/projects/<slug>/<uuid>.jsonl`, 1.3 MB here) straight into the engine. That
file holds **raw-UTF-8** wide chars (99 lines with em-dashes; 0 `\u`-escaped) — Claude's
own output is full of em-dashes/arrows. Loading that large multi-line 16-bit string →
the same JSC rope line-split spin.

**Why the fold can't fix this:** the fold sanitizes *static plugin files*. The transcript
is *dynamically generated conversation content*. The spin needs a LARGE multi-line 16-bit
string, which is exactly a resumed transcript (or a long live session's accumulated
history). So: tiny fresh sessions idle (canary), but **resumes and long sessions spin**.
A launcher could fold the transcript before `-c`/`-r` (raw UTF-8, so `asciify-wide` would
catch it) — but that mutates history and still can't cover mid-session accumulation. The
only complete fix is the **engine** (upstream).

**Actions taken:**
- Killed the hung 2.1.220 `-c` (exact PID 8837 only; never broad — other Claude sessions
  run concurrently, incl. this one on 2.1.179 / PID 1169).
- **Rolled the live symlink back to 2.1.179.** Machine is safe on the pinned engine again.

**Verdict:** 2.1.220 is **not viable for real use** on this machine yet — the spin is
triggered by ordinary conversation content, not just plugin files. Stay on 2.1.179 until
the engine bug is fixed upstream (the bug report is the lever). **The upstream-sync /
`__ulock_wait` work is still worth keeping and committing** — any future version needs it
just to load, so when the engine IS fixed we're one symlink away.

**Lesson (for the runbook):** validating a version upgrade must include **`claude -c`
resume of a real (wide-char-laden) transcript**, not just a fresh `--version`/canary.

## Follow-ups (tracked, not blocking)

- Commit the conflict-free merge on `sync/upstream-newest-claude`; decide push (our
  history was rewritten → force-push). This re-converges avxemu work with upstream.
- Upstream still lacks the wide-char defense (Task 2/4) — now MORE clearly needed
  since the spin persists at 2.1.220.
- Consider extending the preflight to user-settings SessionStart hooks (currently
  plugin-only). Low priority (self-inflicted vector).
