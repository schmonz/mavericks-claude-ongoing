# FINDINGS — the no-AVX2 Claude Code startup spin (SOLVED)

The authoritative answer to the solved startup spin. Investigation history,
dead ends, and superseded plans live in git.

Host shorthand: `oracle-air` = the AVX2 Haswell box used as the correctness
oracle. `target` = the no-AVX2 Mavericks (10.9) machine that spins.

---

## The bug in one paragraph

Claude Code **≥ 2.1.183**, run on a **no-AVX2** Mac via the Mavericks launcher +
`libavxemu` (AVX2 trap-and-emulate), pegs a core **indefinitely** at startup when
any **SessionStart hook emits a character above U+00FF** in its multi-line JSON
`additionalContext`. In practice that hook is the **superpowers plugin's**
`using-superpowers/SKILL.md`, whose em-dashes/arrows are the trigger. **2.1.179 is
fine** (different engine). The TUI reaches its normal prompt, but a background loop
never ends.

## Root cause — SOLVED 2026-08-10: an avxemu 16-bit decode bug. Fixed; the spin is dead.

> **FINAL.** Supersedes both earlier framings ("condition-dependent unbounded loop",
> 2026-07-02; "finite work ~100×/op slower", 2026-07-04/05). Both were wrong about the
> mechanism — though each held a piece: the loop WAS effectively unbounded, and the
> per-op emulation WAS involved. The truth: **the emulator returned a wrong answer.**

- A character > U+00FF forces JavaScriptCore's **16-bit (UTF-16) string**
  representation. The app line-splits it; the hot native routine is a **16-bit
  character search** (`fn44058`, `+0x256e290` in 2.1.185) whose SIMD loop is
  `vpcmpeqw` / `vpmovmskb` / `test`+`je` / **`lzcnt cx,di`** (`66 f3 0f bd cf`,
  `+0x256e58e`) — a **16-bit** lzcnt.
- **The bug: avxemu's decoder dropped the `66` operand-size prefix on lzcnt/tzcnt**
  (`decode.c`: `opsize = rexW ? 64 : 32`) and emulated the op as **32-bit**. After
  `vpmovmskb` the source's upper half is zero, so `lzcnt32 = 16 + lzcnt16` — **every
  emulated result was off by +16.** JSC's character-index math then went wrong and its
  search loop **never terminated**. The ~85.8M observed `lzcnt` executions were the
  *malfunction*, not intrinsic work.
- **Why native was always fine:** real CPUs run the true 16-bit `lzcnt` → correct
  result → the search completes in well under a second (`oracle-air`: ~0.9 CPU-s, wide
  and ASCII alike). Wrong-vs-right, not slow-vs-fast. This is why the hang was
  emulation-only and why **no performance-side fix could ever work** — relocation,
  native lowering, minspill were all built, all correct, all irrelevant.
- **The fix (one line + write-back semantics), avxemu commit `6aa6842`** on
  `sync/upstream-newest-claude` in `../Mavericks-Porting-Resources`:
  - `decode.c`: `opsize = rexW ? 64 : (has66 ? 16 : 32)` (mirrors MOVBE's handling);
  - `tramp.c`/`handler.c`: 16-bit results merge into the low word of dst (hardware
    preserves bits 63:16);
  - `test/zcnt16.c` (+ `build.sh [6i]`): hermetic regression — the exact spin bytes
    through production `decode()`+`bmi_exec` vs hand-computed truth.
- **Verified on the target:** the poisoned repro that spun forever on 2.1.185 AND
  2.1.220 idles in ~9 s with the fixed dylib (minspill on or off); `claude -c` resume
  of the real 2.5 MB wide transcript — the vector no input-sanitizing could cover —
  idles in ~12 s. **All input vectors fixed at once**, because the fix is in the
  emulator, not the input. Transliteration/launcher defenses remain as
  defense-in-depth but are no longer load-bearing.
- **There is no Anthropic/Bun bug.** Claude Code behaves correctly on all supported
  hardware; the "engine pathology" was our emulator feeding the engine wrong
  arithmetic. (`JSC_*` flags never helping, and `useJIT=false` still spinning, are
  both consistent: the miscomputed loop is in compiled C++, below codegen.)
- **How it eluded us:** the emulator's differential suites covered 32/64-bit
  lzcnt but never a 16-bit (`66`-prefixed) one, and every hermetic test hand-built
  its `decoded` structs — bypassing the very decoder that carried the bug. The
  suspicion that "emulated AVX2 is slow" was so plausible that wrongness was never
  on the suspect list. Durable lesson: **when emulated code loops forever, check
  the emulation's *correctness* at the looping instruction before its *speed*** —
  a loop that never exits is more often reading a wrong value than running slowly.

## The 2026-07 mitigation — REMOVED 2026-08-13

The interim workaround was to **transliterate the ~6 non-Latin1 punctuation
characters** out of the hook payload (`—`→`--`, `→`→`->`, …), first by hand and
then automatically: a defended launcher that folded the whole plugin cache to
`<= U+00FF` on every start and refused to launch if an enabled SessionStart hook
still emitted a wide char.

All of it is **gone**, because the emulator fix removes the reason for it. Removed
on 2026-08-13: the launcher's wide-character block (`MF-LOCAL (1)`), `$MF/asciify-wide`,
77 mangled `.wide-bak` plugin files (restored to their real punctuation), the
`grep-fix.sh` PreToolUse hook (upstream now sets `CLAUDE_CODE_USE_NATIVE_FILE_SEARCH=0`
and deletes the hook itself), and `~/.claude/hooks/detect-grep-mismatch.sh`.
Post-update regression check: `scripts/spin_canary.sh`.

## Scope and ownership

- **Trigger shape:** multi-line JSON hook output × one char > U+00FF. Single-line
  wide JSON does not trigger; multi-line ASCII does not; the plugin is the innocent
  messenger, not the mechanism.
- **Ownership: Anthropic's embedded Bun FORK.** "Bun v1.4.0" is not a public
  release (latest public = 1.3.14); Claude 2.1.183+ embeds a fork of Bun's
  unreleased main (build hashes `324c5f012` in .185, `63bb0ca0d` in .197). Stock
  Bun 1.3.14 AND today's public 1.4.0-canary both run a hook-shaped string battery
  clean under identical emulation, so the fork (or the app path) owns it — report
  to Anthropic first; Bun via them.
- **No modern-hardware repro:** the exact payload that hangs the `target` forever
  costs AVX2 hardware nothing measurable. The bug needs the emulated slow-CPU
  condition to manifest at all.

## Postscript — the ugrep SIGSEGV was never avxemu (resolved 2026-08-13)

A separate crash muddied the water for two days: with native file search on,
`grep` (re-exec'd as the binary's embedded **ugrep**) SIGSEGV'd on 10.9 even with
avxemu loaded, and the AVX2 ops right before the fault made avxemu look guilty.
It wasn't. Root cause is the **same `10.9-dyld-skips-__TEXT,__init_offsets`
constructor bug** as the 2.1.229 mimalloc startup crash: ugrep's SIMD
CPU-feature dispatch table is initialized by an `__init_offsets` constructor that
10.9's dyld silently skips, leaving a null function pointer → `call 0x0`. The
emulated AVX2 ops were just the last thing to run before it.

Fixed by Wowfunhappy's `mavericks-legacy-support/src/init_offsets.c`, now in the
shipped `libSystemWrapper.dylib`. Controlled proof (avxemu held constant): new
wrapper → exit 0 ×3; old wrapper → 139 ×3; new wrapper with *only*
`init_offsets.c` removed → 139 ×3. Both avxemu-side hypotheses (mis-emulated op,
`mem_read` over-read fixup) were red herrings. Durable lesson, and it is the same
one as the spin: **when emulated code misbehaves, first ask whether the thing that
did not run is the loader, not the emulator.**

## The evidence (index into `evidence/2026-07-02-recurrence/`, in git history)

- `bun-repro-battery.js` — plain-Bun hook-shaped string battery (stock 1.3.14 +
  canary both pass under emulation).
- `payload_pretty_wide.json` / `payload_pretty_ascii.json` — the plugin-free
  minimal repro pair (multi-line JSON ± one em-dash).
- `hook-ab-results.txt`, `hook-bisect-results.txt` — the plugin off/on and payload
  bisection runs (100% separation).
- `forensic-phaseA-hook-string.out` — lldb dump catching the rope resolver
  scanning the hook JSON out of live registers.
- `lldbsnap-150x1s.out`, `faultsnap-dense-*.gz` — execution-stream samples.
- `wrapper-defense.patch` — the launcher defense diff for the installer.

## Diagnostic tooling

The investigation-era harnesses (`lldb_sampler.py`, `lldb_phasea_forensic.py`,
`faultsnap_recur.py`, `hook_ab.sh`, `hook_bisect.sh`, `jsc_flag_sweep.sh`, the
`pyte_*` family, the version-pinned `claude_179`/`claude_185` launchers) were
deleted on 2026-08-13 and live in git history. What survives in `../scripts/` is
what is still useful after the fix: `spin_canary.sh` + `pyte_ttidle.py`
(post-update regression check) and `fetch-version.sh`.

## What shipped upstream

All of it. Wowfunhappy's `Mavericks-Porting-Resources` master (`59cb1e6`) is
exactly our two merges — PR #2 `avxemu-latest-claude` (the `66`-prefix
lzcnt/tzcnt decode fix and its `zcnt16` regression, VPMOVMSKB's 16-bit mask,
jump-table-aware `patch_safe`, the mulx SIGILL fix, the reloctest rel32-range
fixes) and PR #3 `change-dylib-grow-add` (`-grow`/`-add`). The launcher
grep-speedup went into `mavericksforever.com/claude/install.sh` directly. All
three are live in the site's shipped artifacts — verified by dlopen'ing the
shipped `libavxemu.dylib` and asking its own `decode()` about `66 f3 0f bd cf`
(reports `opsize=16`).

Branch `avxemu-minspill-bmi-tier` was deliberately **not** upstreamed: it is a
real speedup for register-resident BMI, but Claude Code's hot path is
memory-operand BMI, which the minspill tier declines. Kept for a future workload.

## Why avxemu still rides in on DYLD_INSERT_LIBRARIES (2026-08-13)

The env var is inherited by every child process, which is why a scrub
(`DYLD_INSERT_LIBRARIES: ""`) has to sit in settings. Baking the dependency into
the binary instead — `change_dylib`'s `-add` was written with exactly this in
mind — looks tidier. Measured, on 2.1.232, it does not work:

| how avxemu is supplied | result |
|---|---|
| `-add` (appended last) | SIGSEGV in `mav_run_init_offsets` |
| appended, `AVXEMU_DISABLE=1` | **same SIGSEGV** — avxemu was never the cause |
| repurpose load command #1 | dyld: `Symbol not found: _uidna_nameToASCII` |
| avxemu as a dependency of libS | loads, then hangs at ~50% CPU |
| `-insert` at ordinal 1 (new) | reaches Bun startup, then its crash handler + hang |
| **`DYLD_INSERT_LIBRARIES`** | **works** |

Three things came out of the attempt, and they outlast the question:

1. **`-grow` was corrupting modern binaries.** Growing lowers `__TEXT.vmaddr` a
   page; `__TEXT,__init_offsets` holds offsets *from the mach header*, so every
   initializer address came out a page low — a loader-time crash on any build
   with that section, i.e. every Claude Code ≥ 2.1.229, through the wrapper's own
   `-grow` path. Same bug class as the `LC_FUNCTION_STARTS` delta we already fix.
   Branch `macho-grow-init-offsets`.
2. **`-delete` produced unloadable binaries.** Library ordinals are 1-based
   indices into the dylib load commands; deleting one shifts the rest, and
   nothing renumbered them. dyld catches it (`library ordinal (4) too big`)
   because `dyld_stub_binder` holds the highest index. Branch
   `change-dylib-insert-renumber`, which also adds `-insert` (load-order control
   needs renumbering to be correct — that's why the two arrived together).
3. **Repurposing a load command is never valid** under a two-level namespace:
   symbols name their library by ordinal, so slot #1 still meant "ICU" to every
   symbol that had been bound to it.

The remaining failure is specific to this binary, not to the idea: the *same*
grown-and-inserted image runs fine when avxemu is also supplied via
`DYLD_INSERT_LIBRARIES`. An inserted library is initialized ahead of the entire
dependency graph; a linked one, however early its ordinal, is initialized inside
it — and something in Claude Code's startup needs the emulator armed before that.

**Linkage does work in general**, measured with a small AVX2 program (`vpaddd
ymm`, which SIGILLs bare on this CPU):

| configuration | parent | child (`fork`+`exec`) |
|---|---|---|
| bare | SIGILL 132 | — |
| `DYLD_INSERT_LIBRARIES` | ok | **ok — inherited** |
| avxemu linked into parent only | **ok** | SIGILL 132 |
| avxemu linked into both | ok | ok |

So the trade is about *reach*, not viability. The env var emulates the process
and everything it spawns, which is why the settings scrub exists to switch it
back off for children; linkage emulates exactly one binary and cannot leak, but
each binary needs its own load command. Linkage would also have immunised the
one case that actually bit us — the `find`/`grep` shims re-exec the claude
binary with the env scrubbed, which is exactly how embedded bfs came to SIGILL
132 (see the 2026-08 native-search notes). Startup cost is a wash: 4.2 ms/run
linked vs 4.8 ms/run inserted, and a plain binary pays nothing either way.

## The one thing still local

The wrapper passes its injected flags in equals form
(`--mcp-config=…`, `--settings=…`). `--mcp-config <configs...>` is variadic, so
in upstream's space form it swallows the user's first positional — `claude mcp
list` fails with "MCP config file not found: $PWD/mcp". Bare `claude` never shows
it, which is why it survives upstream. Worth a fourth PR; re-apply it after any
`install.sh` run, which overwrites `/usr/local/bin/claude`.
