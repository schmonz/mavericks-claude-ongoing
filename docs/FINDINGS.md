# FINDINGS — the no-AVX2 Claude Code startup spin (SOLVED)

The authoritative answer. For *how* we got here (the chronological investigation
and every dead end) see `archive/RULED-OUT.md`; for *how we could have found it
faster* see `RETROSPECTIVE.md`; for *what remains* see the umbrella plan
`superpowers/plans/2026-07-03-loose-ends-to-completion.md`.

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

## Root cause

- A character > U+00FF forces JavaScriptCore's **16-bit (UTF-16) string**
  representation. The engine's ingestion of that hook output then enters an
  **unbounded loop** — phase A is a UTF-16 rope/scan (`+0x256eaf5`); phase D is
  continuous JIT cross-modifying-code fencing (`cpuid`).
- It manifests **only under AVX2 emulation on the slow no-AVX2 CPU**. Not a
  "same work, ~100× slower" effect — a **timing/condition-dependent** pathology
  that simply does not occur at native speed (verified: identical payload costs
  `oracle-air` ~0.9 CPU-s either way; the `target` never finishes).
- **No JSC option disables it:** all seven `JSC_*` arms (incl. `useJIT=false`)
  still peg — the loop is **below codegen, in the C++ string layer**.

## The fix (validated)

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
