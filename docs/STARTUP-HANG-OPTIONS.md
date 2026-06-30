# Startup-spin — FRESH-AGENT BRIEF (high-effort; stay focused)

> **⚠️ SUPERSEDED IN KEY PARTS (2026-06-30) — read `docs/RULED-OUT.md` (the 2026-06-30
> entries) FIRST.** This brief's central thesis — "the spin is catastrophically slow
> *emulated AVX2*, dominated by the SIGILL/sigreturn trap tax, fix it in avxemu" — has been
> **DISPROVEN by measurement**:
> - The spin is **pure compute, ~0 syscalls** (no sigreturn storm; that was the pre-
>   trampoline era).
> - Emulation is only **~32%** of the cost; eliminating it 100% (native codegen, verified)
>   does **not** collapse the spin — both native-ON and native-OFF peg ≥240s while 179 idles.
> - The bottleneck is **Bun(JSC)'s JIT'd execution of one ~2KB hot loop** introduced by the
>   179→183 app regression; the SAME .185 JS runs fine on clode/Node ⇒ Bun-runtime-specific,
>   not algorithmic, not "no-AVX2".
> - ⇒ **avxemu emulation-optimization (the "Heroic fix tracks" below: native shim / hot-loop
>   JIT / relocation / native codegen) is RULED OUT as the startup fix** (ceiling ~1.5×).
>   Milestones A & B were built, are correct, and are ruled out — see RULED-OUT.
> The sections below remain useful for the SETTLED facts (trust gate, repro, repro discipline,
> tooling walls) and history, but ignore their "fix lives in avxemu" framing.



**This is a heroic-effort problem. The cheap levers are exhausted.** Read this whole
brief and `RULED-OUT.md` BEFORE running anything. Most "interesting ideas" here have
already been tried and are noise or dead — re-running them is how the last ~2 sessions
were burned.

## The bug, stated correctly (supersedes all "transcript/>5MB" framing)

Upstream Claude Code **2.1.183+** (Bun binary) on the no-AVX2 Mac (via the Mavericks
launcher + `libavxemu` AVX2 trap-and-emulate) **pegs one core for minutes at startup**
and the TUI is ~unusable. **2.1.179 does NOT.** It is a clean **version regression
179→183**.

**Root nature is SETTLED (do not re-derive):**
- It is **emulated AVX2, finite but catastrophically slow.** Emulation is *correct*
  (Haswell differential oracle: 0 failures, bit-exact). dtrace on the live spin:
  **`sigreturn` = 52,306/3s** (everything else <250; zero writes) → ~17,000 emulated
  instructions/sec → **~60µs per AVX2 instruction, dominated by the SIGILL
  signal-delivery + sigreturn trap**, not the emulation math.
- **Trigger is the TRUST gate, content-independent.** A *trusted* project spins; an
  untrusted one idles (blocks at the trust dialog before the hot code). **Reproduces
  in an EMPTY dir + one README**, `projects[<path>]={hasTrustDialogAccepted:true}`.
  No transcript / project history / cwd needed. (The old "5MB transcript knee" was a
  3-project coincidence; the `aHf`/`iHf` scanner is byte-identical 179↔183.)
- It is **post-render, main-thread**: the full TUI renders correctly, THEN the main
  thread wedges in the emulated loop, starving the event loop (input barely echoes).

## The two real questions

1. **(FIX, primary)** Get startup from minutes → a few seconds. Does NOT require
   naming the JS function. See "Heroic fix tracks."
2. **(NAME, secondary, currently BLOCKED)** Identify the *new-in-183 JS call* that
   issues the hot AVX2 work. Blocked by tooling (see "Walls"). Only pursue if a track
   below needs it.

## DO NOT RE-DERIVE (settled — burning time here is the failure mode)

- That it's emulated-AVX2 / finite-but-slow / correct emulation. PROVEN (dtrace,
  oracle). The `sigreturn` storm is confirmation, not news.
- That 179 idles, untrusted idles, clode (Node) idles. Multi-run reliable.
- That trusted 185/183 + real plugins spins. Multi-run reliable.
- That the render core is unchanged 179↔183 (`High write ratio` code byte-identical).

## DO NOT CHASE (tried this session — all noise or dead)

- **Plugins / skills / hooks as "the input":** RED HERRING. `zeroskills` (plugins, 0
  SKILL.md) spins; superpowers hook neutralized → spins; 1 vs 43 skills identical;
  `DISABLE_BUNDLED_SKILLS`, `CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT`, no-`--mcp-config` →
  all no-ops. Empty plugin cache is **BIMODAL** (idle/spin) due to marketplace sync —
  do NOT treat a single idle draw as a finding (this trap was hit twice).
- **Terminal capability queries (DA/XTVERSION/OSC11):** REFUTED via a pyte terminal
  that answers them — spins identically.
- **tmux:** spins outside tmux too.
- **The computer-use MCP:** byte-identical spin without it.
- **Our `libSystemWrapper` write shim:** cleared (breaks on EAGAIN; passthrough).
- **Headless `-p` profiler / `CLAUDE_CODE_PROFILE_STARTUP`:** localizes a DIFFERENT,
  pre-existing slow path (the **grove** consumer-terms check `Sst`/`Wca`, present in
  179 too), NOT our regression. The interactive profiler is gated off
  (`av()` guarded by `Lr()=!isInteractive`).

## WALLS (don't re-attempt without a genuinely new idea)

- **Bun CDP inspector:** connects, but **cannot extract while the main thread is
  wedged** — `Debugger.pause` never hits a JS safepoint (stuck in long native call);
  `Profiler.stop` is serviced on the blocked main loop (never returned in 45 min).
- **Native `sample`/dtrace `ustack()`:** give the native hot frame but **JIT frames
  are anonymous** → no JS function names. Binary is stripped.
- **`--debug` log:** startup logs complete in ~3.6s then the spin runs **silently**
  (the hot code logs nothing); 179-only log lines are just background tasks 183
  starves, not the cause.
- **clode/Node:** doesn't reproduce (no emulation) → can't profile the hot path there.

## RELIABLE REPRO + HARNESSES (use these; trust pyte + external `ps`, NOT expect)

- **Everything runs from this repo** (cwd = repo root). The harnesses in `scripts/`
  are self-contained — each resolves its launcher (`scripts/claude_185`) relative to
  itself, so there's no `/tmp` bootstrap. See `scripts/README.md` for what each is +
  a one-breath repro. (The only `/tmp` use is runtime scratch: `/tmp/spin.pid`,
  `/tmp/cj.bak`.)
- Trust the test dir: set `~/.claude.json` `projects["/…/trusttest"]={"hasTrustDialogAccepted":true}`,
  launch in it. Always restore `~/.claude.json` after (back up first).
- `scripts/pyte_watch.py <secs>` — faithful pyte VT100, answers queries, prints CPU% per
  3s. `LAUNCHER=scripts/claude_179|claude_185` env selects version. The reliable signal.
- `scripts/pyte_type.py` — writes the child pid to `/tmp/spin.pid`, types into it, holds
  it alive for external probing (dtrace/lsof). (NOTE: `pyte_watch.py` does NOT write
  the pidfile — use `pyte_type.py` when you need the pid.)
- Launchers: `scripts/claude_179`, `scripts/claude_185` (DYLD-inject avxemu + patch).
  Fetch other versions with `scripts/fetch-version.sh <ver>`.
- **The spin is finite and its duration varies run-to-run** — sometimes it completes
  in <12s (looks idle), usually it runs 90s+. Poll CPU and confirm >70% before you
  measure; never conclude from one run.

## HEROIC FIX TRACKS (the point of this brief)

### C — Native shim of the hot AVX2 routine (surgical; most likely to hit "seconds")
The hot loop is ONE (or few) native Bun routine(s) executing AVX2 in a tight loop.
Identify it, replace it with a scalar/SSE C impl in the dylib (DYLD interpose +
5-byte jmp patch, exactly like avxemu already does for cpuid/lzcnt).
1. Catch the spin (poll CPU>70 via `pyte_type.py` + `/tmp/spin.pid`), grab the
   `__TEXT` base (`vmmap PID | grep 2.1.185`), and the hot user PC via
   `sudo dtrace -n 'profile-1999 /pid==PID/ { @[arg1]=count(); } tick-3s{exit(0);}'`.
   Compute `hotPC - base` = binary offset. (Prior record's transcript-spin hot frame
   was `+0x256eaf5`; CONFIRM whether the *startup* spin's offset differs — if so it's
   a genuinely different routine and that's the new-in-183 native target.)
2. `otool -tV` / lldb-disassemble at that offset; recover the routine's ABI/contract
   (it's stripped Zig). Likely a simdutf/simdjson transcoder or string-width kernel.
3. Interpose a correct scalar/SSE4 version. Bit-exactness matters (oracle it).
   Payoff estimate: a few MB of transcode at native-ish speed = sub-second.

### D — Hot-loop JIT in the emulator (general; bigger; also a durable win for all code)
Today every AVX2 instruction is a per-run trampoline thunk → the ~60µs/instr trap
tax. Detect a hot run/loop and JIT-translate it ONCE into a native SSE4 block run in
a loop (no per-instruction SIGILL). Attacks the trap overhead directly; helps every
emulation-heavy workload. Start from `tramp.c` (the trampoline machinery).
Payoff estimate: minutes (millions of insns @ 17K/s) → ms at native loop speed.

### Realistic answer to "can this reach a few seconds?"
**Yes, plausibly** — both C and D target the dominant cost (per-instruction trap /
slow kernel). A multi-minute spin is ~millions of AVX2 instructions; run natively in
a loop that's milliseconds. Neither is cheap; both are heroic.

### Lower-value / fallback
- **NAME the JS call** (only if C needs the JS-side input): static 179→183 diff of
  `build/2.1.{179,183}/cli.cjs` (17MB minified, no clean anchor — render core
  unchanged, runtime levers are noise). Or find a Bun/JSC JIT perf-map mechanism to
  symbolicate `ustack()` frames (untried; may not exist in the stripped build).
- **Escape:** mature `clode` (Node runtime) into the daily driver — sidesteps Bun's
  AVX2 assumption. But the user considers clode (and pinning 179) **temporary
  instruments, not the fix.**

## FOCUS DISCIPLINE (the meta-failure to avoid)

- **Consult this doc + `RULED-OUT.md` before every experiment.** If it's listed
  above, don't run it.
- **Never conclude from one run.** Repeat at least 3x; this system is bimodal/noisy.
- **Don't extrapolate a lucky idle into "X is the input."** That mistake was made
  twice (skills, then plugins).
- The goal is the **fix (track C or D)**, not re-characterizing the spin. If you find
  yourself re-proving "it's slow emulated AVX2," stop — that's done.

## Setup (orient here)

- No-AVX2 Mac (Ivy Bridge / 10.9.5). Upstream Bun binary at
  `~/.local/share/claude/versions/<ver>`, launched via the Mavericks wrapper
  (`/usr/local/bin/claude`; the installed copy is `/tmp/claude_fast`). Our pinned
  launchers `scripts/claude_185` / `scripts/claude_179` are `sed`-derived from it and
  DYLD-inject `libavxemu.dylib`.
- **This repo** (`../mavericks-claude-ongoing`, your cwd) holds the docs/plan/tools.
  External siblings it references by absolute path:
  - avxemu + shim source: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/`
    (`avxemu/build.sh` builds + differential-tests on the Haswell box; shim is
    `modern_api_polyfills.c`).
  - extracted JS bundles for the static-diff fallback:
    `/Users/schmonz/Documents/code/trees/clode/build/2.1.<v>/cli.cjs` (the `clode`
    repo extracts these; it runs JS under Node — a different runtime, NOT a Bun repack).

## Dylib knobs (in `avxemu/src/handler.c`, some prototyped/reverted)
- `AVXEMU_OPSTATS=1` (+`AVXEMU_FULLTHUNK=1`) — emulated-op histogram.
- `AVXEMU_CPUID_LOG=1`; `AVXEMU_CPUID_NOAVX2_AT=<vmaddr>`.
- Committed: `AVXEMU_FAKE_CPUID`, `AVXEMU_CPUID_SET/CLR`, `AVXEMU_DISABLE`,
  `AVXEMU_FORCETRAMP`, `AVXEMU_FORCEPATCH`.
- Note: global no-AVX2 (un-fake cpuid) makes the app **hang at boot** — the no-AVX2
  fallback is broken; faking AVX2 is required just to start. Per-site cpuid→scalar at
  all 10 leaf-7 sites still pegs → the hot code's AVX2 is **unconditional Bun code**,
  not cpuid-dispatched. So cpuid tricks are dead; only C/D remain.
