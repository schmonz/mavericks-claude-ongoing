# RULED-OUT — the no-AVX2 startup-spin investigation

Working log of what we **eliminated** while diagnosing why the upstream Claude Code
Bun binary (2.1.185), run on a no-AVX2 Mac via the Mavericks launcher + `libavxemu`
(AVX2 trap-and-emulate), **pegs one core at 100% for minutes at startup** on some
projects.

## Established facts (the anchor)

- TUI is reached reliably (~6.6s) and **normal/small projects idle fine** — the
  machine is usable for ordinary work.
- The peg is **post-render, main-thread, and emulation is *correct*** (Haswell
  differential oracle: 0 failures, bit-exact vs real AVX2). So it's genuine,
  finite work — just ~300× slower emulated.
- **Trigger is `hasTrustDialogAccepted` — pure trust gate, content-independent.**
  A **trusted project spins; an untrusted one idles** (it blocks at the trust
  dialog before reaching the spin code). Reproduces in an **empty dir + one
  README forced trusted** (`projects[<path>] = {hasTrustDialogAccepted:true}`).
  So the hot loop is in **content-independent post-trust startup** — no
  transcript/history/cwd needed. (This *supersedes* the old ">5MB transcript"
  trigger, which was a 3-project coincidence — see ruled-out below.) Minimal
  A/B in one empty dir: **179 trusted → 4.1s render, idle; 185 trusted → 7.3s
  render, spins.** Clean version regression, now cheaply bisectable.
- The hot path is a **broad AVX2+BMI2 SIMD routine** (op histogram below), not a
  single shimmable primitive. clode (same logic under Node) runs it fine natively.
  Native sample of the spin: main thread is 100% in **`write()`** (libS shim →
  `__write_nocancel`) under JSC-JIT frames → the SIMD loop sits in the
  **terminal-render/output path**, not file scanning.

## Ruled out

### Is it our bug?
- **Our perf thunks (gpr/tt2 minimal-spill)** — `AVXEMU_FULLTHUNK` A/B: the full
  register-saving thunk pegs identically.
- **Any emulation-correctness bug** — Haswell oracle passed 0 failures (vector +
  BMI), bit-exact. Not a wrong-result / infinite loop.

### What triggers it (by construction)
- **cwd file content/size** — 118MB file-tree replica idled.
- **git / `.git`** — full repo copy *with* `.git` idled.
- **MCP / settings** — identical in the empty dir, which idles.
- **"a registered project exists"** — dimmit (registered, 14 sessions) idles.
- **first-vs-subsequent launch** — fresh project launched 4× stayed idle.
- **`~/.claude.json`** — 36KB total; per-project slice ~1KB.

### Which subsystem (env bisect)
- **DISABLE_BACKGROUND_TASKS, SKIP_PROJECT_BACKFILL, DISABLE_AUTO_MEMORY
  (+MEMORY_BULK_INFLATE +MEMORY_PERIODIC_RESYNC), DISABLE_NONESSENTIAL_TRAFFIC**,
  the **stats cache-warm** (far-future `lastComputedDate`), and a **kitchen-sink of
  every known `DISABLE_*`/`SKIP_*` at once** — all still pegged.
  → it's an **unconditional core path with no off-switch**.

### Is it history-parse / tokenizing (code read of cli.cjs)
- **Local tokenizer / BPE** — token counting is a *server* API call.
- **Blocking history load** — `loadInitialMessages` no-ops without
  `--continue`/`--resume`.
- **`--continue` / `--resume`** — the session is fresh (empty prompt, confirmed).
- Culprit narrowed to `nce`/`loadTranscriptFile`'s **>5MB `aHf` branch**; the exact
  unconditional caller remains an honest static-analysis gap.

### Does updating fix it?
- **2.1.195** — fixes *neither* the spin *nor* the broken no-AVX2 fallback.

### Can we go native?
- **Un-fake AVX2 (report real no-AVX2)** — app hangs before render even in an empty
  dir. The "broken fallback" is real and our bug fixes did **not** cure it; faking
  AVX2 is required just to boot.
- **SSE4 dispatch** — the bun binary ships **no `westmere` (SSE4.2) simdutf kernel**
  (only `haswell`/AVX2, `icelake`/AVX-512, scalar `fallback`). No SSE4 path to pick.
- **clode as a repack mechanism** — conceptual error: clode runs the JS under Node,
  it does not repack the Bun binary.
- **Per-site cpuid → scalar** — reporting no-AVX2 at any single one of the 10 leaf-7
  cpuid sites still pegs (none hung); only *global* no-AVX2 changes anything (and it
  hangs at boot). So the hot code's AVX2 use is **not gated by any single cpuid
  site** → almost certainly **Bun's own *unconditional* AVX2 code**, not a
  cpuid-dispatched library. **cpuid→scalar is dead.** (Sites, for reference:
  `0x010015683a 0x010081fb3c 0x010081fb4a 0x01008143c3 0x010081444d 0x01020f8997
  0x01008d6189 0x010171a063 0x010171a094 0x01007e1322`.)

### What to shim (op histogram, measured live on the 11MB spin)
- **memchr** (`vpcmpeqb`/`vpmovmskb` not dominant) and **simdutf *validation***
  (`vpshufb` absent) — both out.
- **Per-op shimming** — out: a broad ~14-op routine, no single dominant op:
  `vpbroadcastd` 32%, `shlx`, `lzcnt`, `bzhi`, `tzcnt`, `andn`, `vpmovzxbw`,
  `vpsubb`, `vpand`, `vpor`, `vpbroadcastw/q`, `vextracti128`, `vpcmpgtb`. The
  `vpmovzxbw`+shift+broadcast shape looks like **UTF-8→UTF-16 transcoding**
  (`Buffer.toString("utf8")`), not byte-scanning.

## Where this leaves us

Every clean "go native" lever is now eliminated (un-fake hangs; no SSE4 kernel;
cpuid→scalar dead; hot code is unconditional AVX2). What's left is heroic or
out-of-band — see **`STARTUP-HANG-OPTIONS.md`** for the full hand-off. In short:

- **Most direct:** patch the app's embedded JS to **bound the `aHf`/`iHf`
  super-linear re-scan** and **repack** the Bun binary (clode already extracts the
  JS; the missing piece is a repacker).
- **Heroic:** native function-shim of Bun's transcoder; or a **hot-loop JIT** in the
  emulator to attack the ~300× directly.
- **Escape:** run the extracted JS under **Node (clode)** — different runtime, no
  AVX2 assumption.
- **Today, no code:** keep a project's largest transcript **under 5MB**; upstream
  bug report (cap/async `aHf`, move off the main thread) with the 5MB-knee dose-response.

### Reliable characterization (pyte-grade, this session)
Measurement note: **expect harnesses are unreliable here** — whether expect drains
the pty during `after`/`sleep` flips spin↔idle, producing false "fixes" (an early
regex match made it look idle; injecting query responses looked like a fix — both
artifacts). **Ground truth = a pyte VT100 emulator** (`scripts/pyte_watch.py`,
`pyte_term.py`, `pyte_type.py`): faithful render + answers DA/DSR/XTVERSION/OSC11 +
external `ps` CPU. Also `script`+external `ps`. Trust these; not the expect runs.

- **Trigger is the trust gate** (see Established facts). Minimal repro: empty dir +
  one README, `projects[<path>]={hasTrustDialogAccepted:true}`. 179 idles, 183/185 spin.
- **App renders the FULL TUI correctly** (pyte screen = 17 lines: the
  `Claude Code v2.1.185` box, "Welcome back", tips, changelog) **and THEN spins.**
  Post-render, not pre-render.
- **The spin is the established finite-but-~300×-slow SIMD work** (see Established
  facts; NOT a logic loop) now observed in isolation: 100% CPU, **zero further
  output** (screen hash frozen, 0 bytes for 90s+ — long enough to read as "hung"),
  **starving the event loop** so typing echoes only ~2 of 10 chars (your "couldn't
  type"). Hot thread = main thread, ~75% user / 25% system (`ps -M`). The 90s+ with
  no completion is consistent with finite-but-catastrophically-slow, not infinite.
- **dtrace CONFIRMS it's the avxemu SIGILL storm (not write):** on the live spin,
  `syscall:::entry` histogram is **`sigreturn` = 52,306 in 3s** (next: `gettimeofday`
  245; **zero writes**). 52K sigreturns/3s = ~17,000 emulated AVX2 instructions/sec =
  **~60µs per instruction, dominated by SIGILL signal-delivery + sigreturn overhead**,
  not emulation logic. The earlier "write→`__write_nocancel`" sample was sampling bias.
  This just **re-proves the known "finite-but-slow emulated SIMD"** — nothing new, but
  it quantifies the bottleneck as **per-instruction trap overhead** (→ favors a
  hot-loop JIT over micro-optimizing any single op). `sudo` works non-interactively
  here, so dtrace is available; `ustack()` frames are JIT (anonymous) so they don't
  name the JS function — that remains unpinned.
- **Our write shim is cleared.** `modern_api_polyfills.c:498` `write_inject_cancel`
  rewrites the `CSI >4m` needle → `CSI 24m`; partial-write loop **breaks on EAGAIN**.

#### Newly ruled out this session
- **Terminal-query-response wait (hyp. B): REFUTED.** A faithful pyte terminal that
  answers Primary DA (`\e[c`), XTVERSION (`\e[>0q`), and OSC11 bg (`\e]11;?`) spins
  **identically** to a silent one. The loop is not waiting on a terminal reply (it's
  in `write`, not parked in `read`). The "injection fixes it" result was an expect
  draining artifact.
- **tmux: not required.** Spins outside tmux (TERM=xterm-256color, TMUX unset) too.
  The `\ePtmux;`-wrapped queries were incidental.
- **computer-use MCP: exonerated.** Dropping `--mcp-config` (`scripts/claude_185_nomcp`)
  spins **byte-for-byte identically** (same screen hash, same render size).

#### THE INPUT: loaded PLUGINS (corrected — NOT skills)
- **Reliable spin/idle matrix (interactive TUI, pyte, multi-run):**
  - Non-spin (robust): **untrusted** (0,0), **179 full** (0,0), **clode/Node**.
  - Spin (robust): **185 trusted with plugins loaded** — full real set, *or* the
    plugin structure with **0 SKILL.md** (`zeroskills`: 42 plugins, 0 skills) → still
    `87 105 100 100`. So **plugins present, not skills, is the trigger.**
- **CORRECTION of two over-claims** (both from one lucky early idle draw): "skills
  are the input" and then "plugins are the input" were both too strong. The honest,
  multi-run picture:
  - Plugins **present** → reliably spins (full real, `zeroskills`=42 plugins/0 skills,
    1/5/14/43 skills — never idled). *Sufficient* trigger.
  - Plugins **absent** (bare/empty cache, even with
    `DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1`) → **bimodal**: idle/spin/spin,
    idle shows a `93→36→14→4` decay. So a **second slow path exists with no plugins**
    (likely marketplace **sync/network** under emulation). "No plugins" is therefore
    **not a reliable off-switch**, and skills specifically are exonerated
    (`zeroskills` spins; `DISABLE_BUNDLED_SKILLS`/`SIMPLE_SYSTEM_PROMPT`/no-MCP no-ops).
  - **The only ROBUST non-spin conditions are: 179, untrusted, clode/Node.** No clean
    in-185-config lever found — plugin/skill removal is too noisy to be a reliable
    off-switch. The reliable spin is simply **185 + trusted + (real plugins)**.
- Locus in code: `await Promise.all([dae(Mt()), Op()])` under `qe_plugin_skills_load_ms`
  (new in 183); `dae`=skills (exonerated), **`Op`=plugin load** is the suspect. Still
  to pin: the exact heavy call inside the plugin-load path, and whether cost scales
  with plugin count or is a fixed "any plugin present" cost (sync confound makes the
  low-count end hard to measure cleanly).
- NOTE: the **headless (`-p`) profiler is a different path** — it hangs first in the
  pre-existing **grove** consumer-terms check (`Sst`/`Wca`, present in 179 too), so the
  headless checkpoint log (`runHeadless_entry` → hang) localizes the *grove* slowness,
  NOT our regression. Profiler `av()` is gated by `Lr()=!isInteractive`, so it can't
  instrument the interactive (real) spin.

#### JS narrowing (179→183, extracted bundles in `build/`)
- Regression is the **179→183 jump** (cli.cjs 17.12MB→17.33MB, +206KB; 183≈185 within
  ~530B). New-in-183 telemetry markers present in 183, **absent in 179**:
  `skills_sync_wait_ms`, `qe_system_prompt_ms`, `tengu_repl_inner_watchdog`.
- Leading hypothesis: a **sync-wait-on-async deadlock** in new-in-183 startup
  (skills-sync / system-prompt build) — a main-thread busy-loop awaiting something
  the (blocked) event loop can never deliver. Fits every reliable symptom: 100% CPU,
  no output, input starved, non-terminating, trust-gated, content-independent. Not a
  naive `while(!x)`/`Atomics.wait`/`deasync` (counts unchanged). **Next: read the
  `skills_sync_wait_ms` / `qe_system_prompt_ms` call sites in `build/2.1.183/cli.cjs`
  and diff against 179's startup.**

## 2026-06-29 session — premise corrections (authoritative si_addr + byte-level recon)

Measured the spin by histogramming **`si_addr` from the SIGILL handler** (for `#UD`, that
IS the faulting instruction's address — authoritative), then byte-level-disassembled the 4
dominant sites. This overturned three working assumptions:

- **"Hot faulting code is JSC-JIT'd (runtime-generated)": REFUTED.** Every dominant
  faulting site is in the image's **static `__TEXT`** (verified against live `vmmap`),
  not in any anonymous/JIT executable mapping. ("JS JIT generated code" regions were
  non-executing guard pages; the 1.2 GB GC region is non-exec.) → no need for runtime
  code-invalidation / volatile-patch handling.
- **"There is a second `__TEXT` segment the scanner misses": REFUTED.** Exactly **one**
  `__TEXT` segment (vmaddr `0x100000000`, one `__text` section spanning ~57 MB). The "12
  `__TEXT`" matches were *sections*, not segments. Site `0x379d4a2` just sits near the
  tail of the single `__text`.
- **"The startup spin is AVX2-vector emulation": CORRECTED — it's scalar BMI.** The
  AVX2-*vector* ops are already trampolined (trampoline hits outnumber SIGILL traps
  11–39×). The residual, still-trapping spin is **isolated scalar BMI/ABM ops**:
  `LZCNT`/`TZCNT` (legacy `F3 0F BD/BC`, **4 bytes**), plus `SHLX`/`ANDN`. **Root cause
  of the residual: a 4-byte faulting instruction is too short to host a 5-byte `jmp rel32`,
  so the existing run-trampoliner structurally cannot make it trap-free** — it falls to
  ~57µs/trap SIGILL emulation forever. One site (`0x379d4a2`) is a ~125-byte hot loop
  (`tzcnt`/`shlx`/`andn` + indirect call) trapping every iteration. avxemu already
  *emulates* these correctly (`bmi_exec`; `avxemu_patch_lzcnt` forces the fault so they
  aren't silently mis-run as `BSR`/`BSF`) — the gap is purely "can't patch a too-short
  site." → the fix is **block-window relocation** (see the design spec).

**Method note (ruled out as a *measurement technique*):** leaf-PC profiling
(`profile-1999`/`hot-offset.sh`) is **confounded here** — ~75% of samples are `pc=0x0`
(thread inside `write()`) and the rest scatter across emulator/library/anon, because the
core burns cycles *inside the emulator*, not at the faulting instruction. Use the SIGILL
handler's `si_addr` histogram for locating faulting work; leaf-PC for it is dead.

> **Breadcrumb — the more-ambitious path NOT taken (2026-06-29):** when choosing the
> relocation mechanism's depth, the option set was (A) block-window relocator [chosen],
> (B) **a full control-flow-following dynamic binary translator** — trace/region
> formation that *follows branches*, does cross-block register allocation, and relocates
> arbitrary control flow — and (C) special-case the 4 ops [too narrow]. **(B) was
> deferred, not rejected.** It's the right escalation if a future upstream surfaces hot
> faulting code that block-window relocation can't make fast (e.g. large hot regions with
> dense cross-block faulting, or genuinely runtime-JIT'd faulting code). Revisit it if
> Milestone A's pyte A/B shows residual spin that per-window relocation can't close. See
> the design spec §9.

## 2026-06-30 — Milestone A (fault-driven relocation) RULED OUT as the startup fix; premise re-corrected

Milestone A (fault-driven block-window relocation of still-faulting isolated BMI sites)
was implemented and verified CORRECT (avxemu selftest 0 failures incl. lzcnt/tzcnt/shlx/
andn; on-target round-trip + per-op oracle tests vs `bmi_exec`; 3 review rounds caught +
fixed 3 real Criticals). But the pyte A/B end-to-end gate is a **clean negative**:

- **CONTROL (`AVXEMU_RELOC=0`) ×3:** pegs ~101% for the full 60s.
- **TREATMENT (relocation on) ×3:** **indistinguishable — pegs ~101%, never decays.**
- **179 reference:** idles to ~0–2% within seconds. TUI under treatment is wedged (0 chars echo).

**Root cause, via dtrace on module `libavxemu.dylib` (decisive):**
- **Steady-state spin (CPU 99.8%): `on_sigill = 0` faults, `avxemu_emulate ≈ 1.5M calls/sec`
  (12.5M in 8s).** The spin is the **eager load-time TRAMPOLINE path**, not the trap path.
  The AVX2 **vector** hot loop (UTF-8→UTF-16 transcode: `vpbroadcastd`/`vpmovzxbw`/`vpsubb`/
  `vpand`/`vpor`/`vpcmpgtb`/…) is **already trampolined at load** → it never faults → it runs
  trap-free but is still **per-instruction software-emulated millions of times/sec**. THAT
  volume saturates the main thread.
- Relocation fired where applicable (startup-window `on_sigill` 482,843 → 245,223; 80 reloc
  attempts, 48 OK / 32 declined; sites `0x34484a`,`0x3447fb` relocated OK; `0x379d4a2`
  declined by `avxemu_patch_safe` (jump-table/indirect function); `0x2177aef` cool this run
  — bimodal). But these traps are a **transient minority** dwarfed by ~20M emulate calls in
  the same window, so halving them changes nothing observable.

**PREMISE RE-CORRECTION (supersedes the "~57µs SIGILL trap dominates" model in the brief):**
With the current eager-trampoline dylib, the steady-state spin is **trampoline-dispatch-bound
(per-instruction `avxemu_emulate` on already-patched code), NOT trap-bound.** The earlier
`sigreturn` storm (52K/3s) was a pre-/partial-trampoline phase; once the scanner covers the
hot loop, the trap disappears but the per-instruction emulation cost remains and alone is
enough to spin. **Eliminating SIGILL traps cannot collapse this spin** — relocation by design
only touches still-*faulting* sites, and the hot loop doesn't fault.

**What this implies for the fix (→ the real Milestone B):** reduce the cost/count of
*trampolined emulation itself* — emit **native SSE codegen for the dominant AVX2 vector ops
in the hot trampolined loop** (each 256-bit op → 2×128-bit SSE; semantics already in
`exec.c`/`vec_exec`), replacing the per-instruction `avxemu_tramp_dispatch`→`avxemu_emulate`
C-call. Best case keeps vector state in xmm across the run (true block translation, no
spill/reload). This is the spec's original "A1" / Track-D, deferred during planning and now
empirically confirmed as the actual lever. The Milestone-A infrastructure (relocation
mechanism, native-lowering table + oracle discipline, shared RWX pool, `patch_safe`) is the
reusable foundation for it — Milestone A is correct, merged-worthy infra that does not by
itself move startup.

> **Breadcrumb (still open):** if native-lowering the trampolined vector loop still doesn't
> reach parity, escalate to the deferred **full control-flow-following DBT** (spec §9) — keep
> vector state in registers across the whole loop, translate the loop body once. The 1.5M/s
> per-instruction rate suggests the spill/reload + dispatch overhead per op is the tax; a
> register-resident translated loop attacks it directly.

## 2026-06-30 — Milestone B *slice* (native codegen for 8 vector ops) RULED OUT; real hot ops identified

After Milestone A was ruled out (above), a spike confirmed register-resident native SSE is
~50× faster/run than per-instruction dispatch (avxemu commit 90f8948, `test/spike_bench.c`)
→ GO for native codegen. A first SLICE wired a register-resident native-SSE codegen path
into the trampoline thunk builder for 8 vector ops {VPBROADCASTD, VPMOVZXBW, VPSUBB, VPAND,
VPOR, VPXOR, VPCMPEQB, VPCMPGTB} (avxemu commit 85b2a2f; 27-case differential oracle green,
reviewed, mutation-tested). **Live dtrace A/B on the spin RULED IT OUT: `avxemu_emulate`
runs at the SAME rate with `AVXEMU_NATIVE=1` (553,238/5s) and `=0` (559,801/5s)** — native
codegen for that op set displaces nothing.

**Why (decisive, execution-weighted `AVXEMU_OPHIST` histogram of C-emulated ops during the
spin; avxemu diag commit 3fe48a4):**
- **`lzcnt` 85.8M (46.8%)** — scalar BMI/GPR — and **`vpbroadcastw` 85.7M (46.8%)** — vector
  — together **93.6%** of all C-emulated instructions. Top 10 ≈ 99.6%. Tail: mulx, shlx,
  bzhi, tzcnt, blsr, andn, shrx (BMI) + vpbroadcastb/q, vpmovmskb, vextracti128, vpaddq.
- **The supported-8 vector ops are only ~0.15% of this workload** — they were the wrong set.
- 78% of trampolined runs are single-instruction, so all-or-nothing-per-run decline is NOT
  the main cause — the dominant ops simply aren't lowered. (lzcnt here is *trampolined* (C
  `bmi_exec` per-instruction), distinct from Milestone A's relocator lzcnt; ~46.8% of the
  spin is scalar BMI the vector-only emitter structurally can't touch.)

**Therefore (the real Milestone B):** native-lower **vpbroadcastw** (fits the vector emitter)
and **lzcnt** (scalar-GPR path wired into the trampoline thunk — the lzcnt→bsr+fixup lowering
already exists in `reloc.c` from Milestone A Task B) = 93.6%; then the BMI tier + vector tail
→ ~99.6%. Building vpbroadcastw+lzcnt first, then re-measure (in progress).

**Test-safety lessons recorded this session (see memory [[no-broad-pkill-claude]]):** (1) the
179 AND 185 launchers inject the SAME `~/.local/share/claude-mavericks/libavxemu.dylib`;
`cp` OVER it crashes the user's running sessions (mmap'd inode) — TEST with an isolated dylib
(`/tmp/avxemu_natslice` + `scripts/claude_185_natslice`/`AVXEMU_TEST_DYLIB`), SHIP via atomic
`mv`. (2) Never broad-`pkill -f versions/2.1.185` — kills the user's other sessions; kill only
the exact spawned child PID. (3) leaf-PC dtrace profiling is confounded here (75% pc=0x0 in
write); use the SIGILL `si_addr` histogram / `AVXEMU_OPHIST` instead.

## 2026-06-30 (late) — Milestone B native codegen RULED OUT; the spin is APP-side JS, NOT emulation cost (major reframe)

Implemented native lowerings for the two dominant emulated ops — `vpbroadcastw` (46.8%) +
`lzcnt` (46.8%) = 93.6% (avxemu commit 16d5f95, reviewed, 46-case oracle green, mutation-
tested). Built isolated dylib, ran a RIGOROUS long trusted A/B with `AVXEMU_NATIVE` toggled:

- **185 native ON (240s): pegged 100% the ENTIRE 240s — never idled.**
- **185 native OFF (240s): pegged 100% the ENTIRE 240s — identical.**
- **179 reference: idle (~0%) within seconds.**
- dtrace (trusted): native ON → the libavxemu emulation path is called **~0 times** (empty
  histogram); native OFF → `avxemu_emulate`/`bmi_exec`/`vec_exec` ~567K/5s. So **native
  codegen FIRES and eliminates ALL per-instruction emulation — yet the spin is unchanged.**
- PC profile (native ON, 100% CPU): the time is in a tight ~2KB **JSC-JIT'd code region at
  `0x119e37xxx`** (anonymous; NOT libavxemu, NOT our `~0x10E` thunk pool, only ~1193/large
  samples in the main image). I.e. the residual spin is the app's OWN jit'd hot loop.

**CONCLUSION (reframes the whole effort):** the startup spin is **dominated by APP-side
JIT'd JS work (the 179→183 regression), not by AVX2/BMI emulation cost.** Eliminating 100%
of the emulation (native-ON, dtrace-confirmed) does not shorten the spin at all. Therefore:
- **The entire avxemu-emulation-optimization strategy is RULED OUT as the startup fix** —
  Milestone A (fault-driven relocation) AND Milestone B (native codegen). Both are correct,
  reviewed, oracle-gated, merged-worthy infra that genuinely removes emulation overhead —
  but that overhead was never the bottleneck. (They remain valuable for emulation-heavy
  workloads generally; they just don't fix THIS startup spin.)
- **The fix must target the APP's 183 regression** — back to the JS-narrowing leads above
  (the new-in-183 `skills_sync_wait_ms` / `qe_system_prompt_ms` / `tengu_repl_inner_watchdog`;
  the 179→183 +206KB cli.cjs diff) — or the ESCAPE options (pin 179; mature clode/Node).
  The hot JIT loop at `0x119e37xxx` is the thing to identify in the JS.

**METHODOLOGY LESSONS THAT CAUSED FALSE POSITIVES THIS SESSION (critical — these wasted real
time and nearly produced a false "fixed"):**
1. **TRUST must be verified intact before EVERY run.** An untrusted project idles at the
   trust gate (no spin). A `~/.claude.json` restore (e.g. a subagent cleaning up) silently
   dropped trusttest's `hasTrustDialogAccepted`, so a whole batch of runs (treatment AND
   control AND a known-non-fix reference) ALL idled — which looked exactly like a fix. Only
   the control + the non-fix reference also idling exposed it. ALWAYS confirm trust right
   before measuring; a valid A/B REQUIRES the control to reliably PEG.
2. **60s windows are far too short.** The spin is MINUTES (>240s; brief notes 7m45s). A 60s
   "pegged" reading cannot distinguish on/off. Measure TIME-TO-IDLE over a long window.
3. **Localize with a user-PC profile by region**, not just dtrace of libavxemu symbols — the
   empty libavxemu histogram under 100% CPU is the tell that the spin left the emulator.
4. (Earlier, still true) leaf-PC profiling is confounded by `write`; use `si_addr` for fault
   localization; isolated dylib + `claude_185_natslice` for safe testing; never broad-pkill.

### Open unknowns (resolve first)
- **Does it terminate, and how long?** Never measured to completion (7m45s observed,
  still pegged). Run to idle on clode (7.2MB) / mtp2 (11MB).
- **Regression vs. data-growth? → RESOLVED: version regression.** Real upstream
  **2.1.179** (shipped avxemu) renders in 3.8s and **idles** on the same 11MB
  project that pegs 185. **2.1.179 is the working baseline** (a borrowed, expiring
  instrument — Anthropic reaps old versions); pin it with `DISABLE_AUTOUPDATER=1`
  (the in-app autoupdater repoints `~/.local/bin/claude` to latest). The mission is
  still to fix the latest version; 179 is just a *running Claude to fix it with*.
- **Transcript-scanner / ">5MB super-linear scan" → RULED OUT.** A full 179/183/185
  JS diff (functions matched by structure + preserved strings, minified names
  normalized) found `aHf`/`iHf`/`nce` (the >5MB scanner + loader) **byte-identical
  across all three** — same forward-cursor scan loop, same 1MB chunks, same callers.
  179 runs the exact same code and idles, so the scanner is **not** the regression
  and "bound the scan" is **not** the fix. The clean "5MB knee" (dimmit 4.82→idle,
  clode 7.2/mtp2 11→peg) was a **3-project coincidence/proxy**, not causation. Where
  it actually is: localized to **179→183** (183≈185, ~530-byte diff; 179→183 = the
  only real jump, +206KB), most likely the new-in-183 **REPL inner render/exec
  restructure** (now carries a `tengu_repl_inner_watchdog` → can stall/spin) and/or
  **skills-load / system-prompt build** (`qe_system_prompt_ms`, `skills_sync_wait_ms`).
  It's a core path with **no env off-switch** (matches the kitchen-sink result), and
  render is SIMD-heavy (string-width / UTF-8 → the measured `vpmovzxbw`/`vpbroadcastd`
  op mix). Next: name the exact function via a JS hot-frame capture on the slow
  machine, then diff 179→183 right there.
