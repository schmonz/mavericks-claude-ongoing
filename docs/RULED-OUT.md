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
