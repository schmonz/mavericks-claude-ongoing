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

## The original mitigation (2026-07 — superseded by the real fix above, kept as defense-in-depth)

**Transliterate the ~6 non-Latin1 punctuation characters** in the hook payload
(`—`→`--`, `–`→`-`, `→`→`->`, `≠`→`!=`). With the plugin's `SKILL.md` ASCII-clean,
2.1.185/197/198 idle in ~9s on the `target` — full functionality, zero loss.
Confirmed by the plugin off/on and payload bisection A/Bs.

Durable version: the **defended launcher** (`scripts/claude-wrapper-defended`)
auto-sanitizes known payloads and refuses to start with an informative message if
any enabled plugin's SessionStart hook still emits a char > U+00FF (gated on the
no-AVX2 branch; bypass `CLAUDE_MF_ALLOW_WIDE_HOOKS=1`). Post-update check:
`scripts/spin_canary.sh`.

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

## The evidence (index into `evidence/2026-07-02-recurrence/`)

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

## Diagnostic + defense tooling (in `../scripts/`)

`lldb_sampler.py` (execution-stream interrupt sampler — fault-stream diagnostics
go blind once the fault storm is fixed), `lldb_phasea_forensic.py` (dump UTF-16
around live registers), `faultsnap_recur.py`, `hook_ab.sh` / `hook_bisect.sh`
(kill-test + payload bisection), `jsc_flag_sweep.sh`, `spin_canary.sh`,
`claude-wrapper-defended`, the `pyte_*` harnesses.

## Fixes produced along the way (avxemu, branch `fix/avxemu-on-upstream`)

Independent of the spin, all general-value and green on both hosts: the **mulx
take-the-high-half SIGILL fix**, **jump-table-aware `patch_safe`**, and the
**reloctest/minspilltest rel32-range test fixes** (the RWX thunk pool lands >2GB
from the test code on modern macOS; fixed test-side). Queued for upstream (plan
Task 6). NOTE: the earlier belief that "avxemu emulation optimization is the fix"
was **wrong** — per-op lowering can't shrink an unbounded loop; it's mitigation at
best (plan Task 7 measures the residual startup speedup).
