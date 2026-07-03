# Ideas / backlog (not yet planned)

Deferred ideas for the Mavericks launcher + `libavxemu`. Distinct from the
startup-spin fix (that has its own plan); these are smaller, opportunistic.

---

## ★ REPORT PLAN (2026-07-02, ownership settled — see RULED-OUT "ownership" entry)

1. **Anthropic (primary)** — github.com/anthropics/claude-code issue: "Claude Code ≥2.1.183 pegs
   CPU indefinitely at startup on no-AVX2 Macs (emulated AVX2) when any SessionStart hook emits a
   char > U+00FF; 2.1.179 fine. Your embedded Bun fork's 1.4.0 line owns the regression (stock
   1.3.14 AND today's public canary pass a hook-shaped battery under identical emulation)."
   Attach: one-em-dash repro, bisection table, phase-A forensics (UTF-16 rope loop) + phase-D
   (cpuid fence churn), JSC flag sweep (incl. useJIT=false pegs), version/hash boundary.
2. **obra/superpowers (secondary, defense-in-depth)** — ASCII-normalize using-superpowers/SKILL.md
   (or sanitize hook output); include the 8-char transliteration diff; frame as "your plugin is
   the innocent messenger; this hardens users on old Macs until Anthropic fixes the engine."
3. **Bun (via Anthropic / optional)** — their engineers co-maintain the fork; a direct public
   issue would lead with "not reproducible on public code."

## (superseded framing) ship the fix + report upstream (root trigger fully characterized)

Bisection DONE (RULED-OUT top): **one non-Latin1 character in any SessionStart hook
additionalContext** triggers the unbounded spin on no-AVX2 + Bun 1.4.0; ASCII-transliterating the
superpowers SKILL.md (6 chars) fixes it outright (validated). Remaining actions:

1. **Apply the fix for real** (user decision): transliterate `—`/`→`/`≠` in the REAL
   `~/.claude/plugins/cache/superpowers-marketplace/superpowers/*/skills/using-superpowers/SKILL.md`
   on no-AVX2 machines (re-apply after plugin updates), or add an ASCII-fication step to the
   Mavericks launcher/installer for plugin hook payloads.
2. **Upstream reports**: (a) obra/superpowers — normalize the skill/hook output to ASCII (or
   document the hazard); (b) Bun — minimal repro: no-AVX2 x86-64 + Bun 1.4.0 (JSC) + a
   SessionStart hook echoing `{"hookSpecificOutput":{"hookEventName":"SessionStart",
   "additionalContext":"~3KB of text with one —"}}` → CPU pegged indefinitely; 1.3.14 OK,
   AVX2 hardware OK. Include the phase-A/D forensics (UTF-16 rope loop + cpuid fence churn).
3. (Optional depth) Identify the exact JSC function that loops (WTF::StringImpl / Yarr?) via the
   deep-bt evidence + Bun 1.4.0 JSC sources — strengthens the upstream report, not needed for the fix.
4. (Optional scope) Jumbo (3KB+) non-ASCII CLAUDE.md with plugin off — closes the "is CLAUDE.md
   ingestion also affected at hook-comparable sizes" caveat (tested innocent only at ~170 B).

## (DONE — see above) bisect WHAT about the superpowers session-start payload triggers the spin

CONDITION FOUND (RULED-OUT top): the superpowers plugin's session-start payload sends Bun 1.4.0's
JSC into unbounded string-scan + recompile churn on no-AVX2; plugin OFF → 185 idles in 9s (3×).
Workaround available NOW: disable the plugin on no-AVX2 machines. Refinements, in value order:

1. **Bisect the payload**: keep the plugin enabled but neuter/truncate its SessionStart hook
   output (edit the hook script inside `/tmp/spin_home/.claude/plugins/...` — throwaway copy) —
   half-size, no-markdown-table, ASCII-only variants → is it SIZE or CONTENT (the `| table |`
   rows? the long lines?)? The loop constants (r13=0xd90=3472, rdi=0xcc0c=52236) should shift
   with the payload and confirm the mapping.
2. **Separate hook vs skills-registration**: superpowers also registers skills; a plugin variant
   with the hook deleted but skills intact (or vice versa) splits the two.
3. **Minimal repro** for upstream: a bare project whose SessionStart hook `echo`s the same JSON
   blob (no plugin at all) — if that spins, it's pure hook-output processing → file a Bun/JSC
   issue (JSC string/regex pathology on no-AVX2 with big hook contexts; engine boundary =
   Bun 1.3.14→1.4.0, RULED-OUT 2026-07-01).
4. If content-shaped: try `JSC_*` env (dumpLinkBufferStats/reportCompileTimes) DURING the spin
   for the recompile-churn half (phase D cpuid fence, fn 48359/52292/51780).

## (DONE 2026-07-02 latest — condition found, see above) identify the JS-level loop behind phase A (the `'\n'`×3472 re-fill)

The recurrence question below is SETTLED (RULED-OUT top, 2026-07-02 later): the spin never ends
(1800s TTIDLE=none), the "module sweep" was only the first-2s fault burst, and the steady state
re-does the same operations on constant data for minutes per phase. Per-op lowering is demoted to
mitigation. The open question is WHAT JS keeps requesting the work. Most actionable probe:

- Attach `scripts/lldb_sampler.py`'s parent lldb session to the pegged pid during phase A and get a
  DEEP backtrace (30+ frames) from the interpreter frame `+0x37cee8b` down — JSC CallFrame walking
  (`$rbp` chain through interpreter frames; codeblock pointers identify the JS function), or read
  the phase-A stable pointers (`r9=0x140a2fde0`, `r12=0x11bc41c80` in the 2026-07-02 run) — one is
  likely the JSString/rope being re-flattened; its contents name the culprit (screen buffer? prompt
  padding?).
- Count fills/sec: breakpoint on the thunk's fill entry with `-o 'breakpoint modify -i 10000'` and
  time between hits → how many re-materializations/sec of the same string.
- Phase D: rerun sampler (now all-thread-aware) to get true attribution; then
  `JSC_dumpLinkBufferStats=1` / `JSC_reportCompileTimes=1` env probes for the compile churn.

## (SETTLED 2026-07-02 later — see RULED-OUT top; kept for method history) string-address RECURRENCE test — is the spin work-bound or condition-bound?

After the mulx fix + fault-storm fix, the spin persists (~87% in native pool thunks) and FAULTSNAP
shows the hot loop scanning Bun BUILTIN JS module source (JSC lex/atom-hash). The open fork that
decides whether per-op lowering can EVER shrink the spin:

- **Work-bound** (finite huge compile): each module source address is hashed a bounded number of
  times → per-op speedup shortens total duration (worth finishing the tier + mem-source bzhi).
- **Condition-bound** (loop/retry/poll): the SAME source addresses are re-scanned indefinitely →
  no per-op speedup can end it; must find + fix the CONDITION (why it re-compiles/re-links forever).

**The test:** lower FAULTSNAP's sample interval (`& 0x3FFF` → `& 0xFFF`), run one 90s spin, and
check whether the captured pointer addresses (e.g. `0x11375dbd0` = ReadStream source) RECUR across
far-apart samples. Recurrence ⇒ condition-bound. Each-address-once ⇒ work-bound. This is ONE 90s
observation and settles the strategy. (The 1800s TTIDLE A/B answers the same question more slowly:
if EITHER arm idles < 1800s it's finite/work-bound; if neither, run this recurrence test.)

**If condition-bound**, likely culprits to chase (JSC on no-AVX2): a compile/tier-up loop that never
reaches the condition to stop because an emulated-hash result differs, or a module-link retry. Probe
with `JSC_dumpLinkBufferStats` / `JSC_reportCompileTimes` env (strings present in the binary) or the
`no_avx2` feature-branch (telemetry-confirmed the binary knows it's no-AVX2, but cpuid-branching was
REFUTED earlier — re-examine whether any JS-visible path keys on it).

---

## Scope the AVX shim to the one binary that needs it (stop it crashing child `node`)

**Problem.** The launcher injects `libavxemu.dylib` via `DYLD_INSERT_LIBRARIES`.
That env var is **inherited by every child process** by design. The native
Claude binary needs the shim (no AVX2 on this CPU); but children like host
`node` (e.g. clode's extractor/tests, any `node`-spawning tool) do **not** — and
the shim actively **crashes** them: `malloc: incorrect checksum for freed
object` (heap corruption). Bare `DYLD_INSERT_LIBRARIES= node --version` runs
fine, so node never needed the shim — the crash is the shim *intruding*.

**Why it crashes node (mechanism, evidenced 2026-06-29).** `libavxemu` is not a
passive trap-and-emulate shim. Inspecting the dylib:
- It has a `__mod_init_func` **constructor** that runs in *every* process that
  loads it, and does **load-time code patching**: a length-disassembler engine
  (`_lde_scan_func`, `_lde_scan_zcnt`, `_lde_cflow`) plus
  `_avxemu_install_trampolines`, `_avxemu_patch_lzcnt`, `_avxemu_build_thunk`,
  and a trampoline pool (`_avxemu_pool_*`). It scans executable code, finds
  AVX2/BMI/lzcnt/tzcnt sites, and rewrites them in place with trampolines.
- It **interposes `signal`/`sigaction`** (the `__interpose` section's two entries
  → `_avxemu_sigaction` @0x8270, `_avxemu_signal` @0x8da0) to own the SIGILL
  handler.

Tuned for the Claude/Bun binary, that scan-and-patch is fine. Forced into `node`
(different layout; V8 runs its own JIT and its own SIGILL/SIGSEGV handlers for
stack guards / Wasm traps), the patch pass + signal interposition stomp memory.

**Current workaround (option A — in place).** Empty the var for children via
Claude Code `~/.claude/settings.json`:
```json
"env": { "DYLD_INSERT_LIBRARIES": "" }
```
The parent (already launched with the shim) is unaffected; children spawn clean.
Cheap and correct *for clode* (node never needs the shim). **Downside:** it's
per-machine config that's easy to forget — a machine missing this block silently
breaks every node-spawning test. (Hit exactly this on 2026-06-29 on a second box.)

**The idea (option B — the principled fix).** Don't use the env var at all. Add
`libavxemu` as an **`LC_LOAD_DYLIB` load command baked into the native Claude
binary's Mach-O header**. Then only that binary loads the shim; nothing is in the
environment, so **no child inherits anything** — the "machine forgot the scrub"
failure class disappears by construction.
- Tooling likely already present: `change_dylib` and `patch_macho` in
  `~/.local/share/claude-mavericks/` are Mach-O load-command surgery.
- **Tradeoffs:** must re-patch on every Claude Code update (the launcher/update
  path could do this automatically); editing load commands invalidates the
  signature → ad-hoc re-sign (already being done for the other patches).

**Option C (noted, not recommended).** macOS strips `DYLD_*` across a child with
hardened runtime lacking `com.apple.security.cs.allow-dyld-environment-variables`
(or SIP-protected / setuid). Could ad-hoc-sign `node` that way — more fragile and
node-specific than B.

**Recommendation.** Keep A as the safety net; pursue **B** so the shim belongs to
the one binary that needs it instead of leaking into every child.
