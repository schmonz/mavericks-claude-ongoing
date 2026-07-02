# RULED-OUT — the no-AVX2 startup-spin investigation

Working log of what we **eliminated** while diagnosing why the upstream Claude Code
Bun binary (2.1.185), run on a no-AVX2 Mac via the Mavericks launcher + `libavxemu`
(AVX2 trap-and-emulate), **pegs one core at 100% for minutes at startup** on some
projects.

## ★★★★★★★ 2026-07-02 (FINAL): ROOT TRIGGER = ONE NON-LATIN1 CHARACTER in the SessionStart hook additionalContext; ASCII-transliteration FIXES it outright

**The bisection (scripts/hook_bisect.sh — plugin ENABLED in every arm, only the hook payload
swapped in the throwaway HOME's plugin cache; 15 interleaved 300s-TTIDLE runs, 100% separation):**

| arm | payload | result |
|---|---|---|
| CTRL ×5 (rounds 1–3) | full SKILL.md content | **pegged** 300s |
| STUB ×2 | tiny fixed string | idle 9s |
| HALF | first 1530 B (contains `—`) | **pegged** |
| FILL | ~3 KB pure-ASCII filler | idle 9s |
| P714 | REAL content, pure-ASCII prefix (cut before the first `—`) | idle 9s |
| **FILL16** | same filler **+ one `—`** | **pegged** |
| **ASCIIFY** | FULL content, 6 chars transliterated (`—`→`--`, `→`→`->`, `≠`→`!=`) | **idle 9s** |

⇒ **The trigger is a single non-Latin1 character** in the hook's additionalContext. Mechanism fit:
a non-Latin1 char forces JSC's 16-bit string representation; the app/engine path that ingests
SessionStart hook output then enters the effectively-unbounded UTF-16 rope/scan loop (phase A,
`+0x256eaf5`) + perpetual recompile fencing (phase D cpuid) — but ONLY on no-AVX2 under Bun 1.4.0
(1.3.14 fine; AVX2 hardware fine). Content mass is irrelevant (3 KB either way); position/count
irrelevant (1 char suffices). The loop constant r13=0xd90=3472 ≈ the escaped context length —
the loop is sized by the whole string, entered because of its 16-bitness.

**SCOPE: hook-path-specific.** Plugin OFF + a CLAUDE.md containing `—`/`→` in the repro project =
idle 9s. Non-ASCII in CLAUDE.md does NOT trigger it (caveat: tested at ~170 B; the hook path was
triggered at 3 KB — a jumbo non-ASCII CLAUDE.md is untested). It is also presumably not
superpowers-specific: ANY plugin/user SessionStart hook emitting non-ASCII additionalContext
should reproduce — that's the minimal upstream repro (a bare hook echoing JSON with one `—`).

**FIXES, best first:** (1) **ASCIIFY the plugin's SKILL.md** (6 chars) or the hook's output —
validated working, zero functionality loss; re-apply on plugin updates. (2) Report upstream:
superpowers repo (normalize skill text to ASCII, or escape non-BMP…-BMP-non-Latin1 in the hook)
AND Bun (JSC 16-bit-string pathology on non-AVX2 x86 with 1.4.0; minimal repro above). (3) The
blunt fallback: disable the plugin on no-AVX2 machines. avxemu is NOT the fix layer (settled).

## (superseded by the FINAL section above) ★★★★★★ 2026-07-02 (latest): CONDITION FOUND — the superpowers plugin's session-start payload triggers the spin; disabling it = 185 idles in 9s

**THE KILL-TEST (`scripts/hook_ab.sh`, 5 interleaved 300s-TTIDLE runs, toggling ONLY
`enabledPlugins.superpowers@superpowers-marketplace` in the throwaway `/tmp/spin_home`):**
- **plugin OFF: TTIDLE = 9s / 9s / 9s** (totalcpu 4.4–4.6s — identical to healthy 2.1.179)
- **plugin ON: TTIDLE = none / none** (pegged all 300s, totalcpu ~304s)
Perfect 3×/2× separation on the previously always-pegging repro. **The trigger is the superpowers
plugin's session-start payload; without it, upstream 2.1.185 is fully usable on the no-AVX2 Mac
TODAY.** This also explains the old trust correlation (hooks/plugins only engage on trusted
projects → untrusted always idled).

**HOW IT WAS FOUND — phase-A forensics (`scripts/lldb_phasea_forensic.py`, output preserved in
`docs/evidence/2026-07-02-recurrence/forensic-phaseA-hook-string.out`):** interrupt-stops during
the pegged phase land in rope-resolver fn 44058/44061 (`+0x256eaf5` frame confirmed EXACTLY) with
`rdx/rsi` pointing INTO a UTF-16 buffer whose content is **the superpowers SessionStart hook
output** (`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":
"<EXTREMELY_IMPORTANT>\nYou have superpowers.…"` + the full using-superpowers skill text). The
loop state is byte-identical across independent runs (`r13=0xd90`=3472, `r14=0xa`, `rdi=0xcc0c`)
= a deterministic, effectively-unbounded (30+ min) string operation over an ~always-the-same
few-tens-of-KB hook string; the deep 40-frame bt (same file) runs interpreter → JIT → rope
resolve, one long JS call, NOT a re-firing hook.

**PHASE-D CORRECTION (supersedes the mischaracterization in the section below):** my earlier
static disassembly used base=slide instead of base=`__TEXT` load address — all phase-D offsets
were short by 0x8000 and the "hash-sweep fn 48306 / byte-emitter fn 52262" read was of the WRONG
code. True sites: leaf `+0x2a4f832` = **`xor eax,eax; cpuid`** in fn 48359 — a serializing fence
that then reads-and-CLEARS a queue (`+0x38` ptr / `+0x44` count) = cross-modifying-code flush
machinery; called per-element from a virtual-call worklist loop (fn 52292) under a `__call_once`
dispatcher (fn 51780). So phase D = **perpetual JIT code-patch fencing** (recompilation churn),
and the "parked thread" worry dissolves (samples pile on cpuid because serialization makes it the
hottest instruction). METHOD LESSON (durable): *static offset = pc − `__TEXT` LOAD ADDRESS*
(includes the 0x100000000 preferred base); before trusting any new offset, verify the arithmetic
against a KNOWN one (rope resolver `+0x256eaf5` was the checksum here — it caught the bug).

**WHERE THIS LEAVES THE INVESTIGATION:** Bun 1.4.0's JSC, on the no-AVX2 target, goes into
effectively-unbounded string-scan + recompile churn when fed the superpowers session-start
payload; Bun 1.3.14 (2.1.179) handles the same payload fine, and 1.4.0 handles it fine on AVX2
hardware (oracle-air). NEXT REFINEMENTS (docs/IDEAS.md top): bisect WHAT about the payload triggers it
(hook additionalContext vs skills registration; size vs content — e.g. binary-search a truncated
hook output); build a minimal standalone repro; then (a) report upstream (Bun/JSC pathological
case), (b) launcher-level mitigation if the trigger is byte-shaped (unlikely), (c) user-level
workaround NOW = disable the superpowers plugin on no-AVX2 machines (or per-project). avxemu
per-op work stays demoted: real ~3×/op mitigation, irrelevant to an unbounded loop.

## (superseded in part — phase-D read corrected above) ★★★★★ 2026-07-02 (later): WORK-vs-CONDITION SETTLED — the spin never ends (≥1800s), per-op lowering CANNOT fix it; PIVOT to finding the condition

The plan's priority-1 experiment (string-address recurrence at higher FAULTSNAP density) was run
and produced a METHOD CORRECTION, a NEW INSTRUMENT, and a STRATEGY VERDICT.

**1. METHOD CORRECTION — FAULTSNAP is blind to the sustained spin (avxemu `0a39a2e`: mask
16384→1024 + seq/mach-time header).** With timestamps, ALL 89 snaps of a 185s pegged run land in
the **first 1.9 seconds** (the startup fault burst, 76/89 from fn-B tzcnt `+0x2f1e0c4`); the fault
stream then goes SILENT while CPU stays 100% for minutes. The fault-storm fix made the steady state
fault-free, so the earlier "recurrence leans WORK-BOUND, 63/90 distinct module sources" reading
(same-day, pre-timestamp) actually characterized only the initial 2-second burst — the "module
sweep" is the BURST, not the spin. Durable: **any fault-stream diagnostic only sees the first ~2s;
instrument the EXECUTION stream instead.**

**2. NEW INSTRUMENT — `scripts/lldb_sampler.py`:** attach lldb to the pegged pid, SIGSTOP-interrupt
~1/s, dump rip + all-thread pcs + GPRs + guarded printable strings in FAULTSNAP format (analyzed by
`scripts/faultsnap_recur.py`). 150 samples over 162s captured (evidence:
`docs/evidence/2026-07-02-recurrence/`). `process handle SIGILL --pass true --stop false` first.

**3. THE STEADY STATE = a sequence of VERY LONG phases re-doing the same operation on constant
data.** Phase A (samples 0–110, ≥2 min, and it had already been running ~1 min pre-attach): ONE
frozen 3-frame chain — rope/UTF-16 resolver `+0x256eaf5` ← JIT ← interpreter `+0x37cee8b` — with
loop registers CONSTANT the whole time (`r13=0xd90`=3472, `r14=0xa`) and the leaf 74% inside a
single full-spill thunk whose op is an SSE 16-bit broadcast-fill (`pxor/movd/pshuflw/pshufd/movdqu`)
writing UTF-16 `0x000a` — i.e. **re-materializing a ~3472-char newline-fill string over and over
for minutes**. Sample split inside phase A: **69.4% thunk spill/restore/flags machinery, 10.8%
actual SSE fill work, 15.3% app-native, 4.5% JIT** — the full-spill frame is ~6× the op. Phase D
(samples 111–150+): a compile/emit loop — bytecode/machine-code byte-emitter (fn 52262
`+0x2da17ad`) + hash-table sweep/rehash with wyhash-style `mulx` hashing (fn 48306, per-entry call
to fn 38954). CAVEAT: the sampler read thread index 0 only; phase D's 39 samples share ONE pc at an
unreachable alignment nop = thread 0 was likely PARKED and the busy thread unsampled → phase-D
attribution unreliable (sampler now records all threads' pcs and follows the moving one).

**4. THE SPIN NEVER ENDS: fresh clean 1800s TTIDLE run = `TTIDLE=none`, totalcpu 1813.8s.** The
sustained spin has now never been observed to terminate (6×300s, 600s+, one 22-min, one 30-min).

**VERDICT — per-op lowering cannot fix the spin; the plan's remaining avxemu levers are DEMOTED to
mitigation.** Even the most favorable reading (astronomically-large finite work) gives ≥30 CPU-min;
the realistic across-the-board minspill win (~3× on phase A by removing the 69% spill share) leaves
≥10 min — not a fix. And the phase structure (same 3472-char fill re-done for minutes; compile/emit
still churning 30 min in) is behaviorally CONDITION-bound: something keeps re-requesting the same
materialization/compilation. **PIVOT: identify the JS-level condition.** Leads, most actionable
first: (a) what keeps producing/flattening a ~3472-char `'\n'`-fill string at the idle REPL —
TUI/screen-buffer redraw? padding? (deep JS stack via lldb at the interpreter frame; probe the
stable pointers r9=`0x140a2fde0` r12=`0x11bc41c80`; count fills/sec); (b) phase-D probes
`JSC_dumpLinkBufferStats` / `JSC_reportCompileTimes`; (c) the engine boundary (Bun 1.4.0 JSC vs
1.3.14 — below) is still the root cause; a JSC/engine option that stops the re-work is the fix
shape. Vector/mem-source minspill remains a real ~3×/op improvement — worth having only if the
condition can't be killed.

## ★★★★ 2026-07-02: BOTH BLOCKERS FIXED + FAULT STORM KILLED — but the spin is NOT startup, and per-op speedups don't shrink it

Session arc (avxemu branch `fix/avxemu-on-upstream`, HEAD `143b5e4`; all three commits
test-verified before landing):

**1. BLOCKER 1 (mulx SIGILL) ROOT-CAUSED + FIXED (`b3b61fd`).** `emit_minspill_mulx` wrote
dlo LAST, so `mulx rax,rax,rax`-style dlo==dhi forms (the take-the-high-half idiom; hardware
writes DEST2=lo then DEST1=hi, equal dests keep HIGH — SDM + `emulate_bmi_reg` order agree)
ended with the LOW half. Static scan of 2.1.185: **hundreds of dlo==dhi sites (459× `mulx
rax,rax,rax` alone)** in the hottest hash paths → corrupted JSC state → wild jump → SIGILL in
the pool. Fix = reorder placement (T=high; dlo=low; dhi=T), same instruction count, correct
under every aliasing. Real-decode-driven test samples added (`_mx19.._mx23`); 1344 differential
cases green; the previously-crashing spin context now runs clean for minutes at 99–100%.
**LESSON (durable): every emitter needs real-binary-derived operand samples — hand-built
decodes miss real `decode.c` combos (here: dst==bmi_dst2).**

**2. CORRECTNESS GATES PASSED.** Target: `AVXEMU_FORCETRAMP=1 AVXEMU_MINSPILL=1 claude --help`
output byte-identical to MINSPILL=0, exit 0 (pre-fix: SIGILL). oracle-air (Haswell): `oracle` +
`bmi_oracle` green = `bmi_exec` matches real silicon. CAVEAT: oracle-air runs macOS 15 now —
`reloctest`/`minspilltest` fail there ENVIRONMENTALLY (RWX pool mmap / dyld-insert blocked;
HEAD~3 fails identically, 202 failures, so NOT a regression) — the injection-based
output==native gate can only run on the Mavericks target.

**3. FAULT STORM FOUND + 72% KILLED (`5da4233`, diagnostic `143b5e4`).** New
`AVXEMU_FAULTHIST=1` (dumps the g_hot still-faulting-RIP table + relocation-decline reasons to
`/tmp/faulthist.out`): the sustained spin was taking ~5.4K SIGILLs/s — **94% from 3 STATIC
zcnt sites** (2× `lzcnt edi,edi` +0x2176a8b/+0x2177aef, 1× `tzcnt ecx,ebx` +0x2f1e0c4), each
declined ONCE for relocation (R5=patch-safety) then faulting+full-emulating forever. NOT JIT
code; NOT cpuid-advertisement-induced. Decline cause: the containing functions hold LLVM
jump-table dispatches (`cmp;ja;lea rip;movsxd ×4;add;jmp *r`) and `collect_branch_targets`
blanket-set has_indirect (zero actual targets in any patch window). Fix: sound jump-table
resolution (exact pattern match incl. cmp/ja or movzx-8bit bound; mark table targets; skip
inline table bytes as data; any mismatch keeps the decline). Live effect: fault total
229K→65K per ~40s; **sigtramp 26%→0%, avxemu handler C 16%→0% of busy samples**. Remaining
leader: fn B (+0x2f1caa0, 18.5KB interpreter-like, its first dispatch's table base is lea'd
far away — needs dataflow; left declined by design).

**4. THE SPIN IS NOT STARTUP — the app is FULLY READY while pegged.** pyte screen render
during a 100%-CPU isolated-HOME spin shows the **normal logged-in REPL prompt** (v2.1.185,
banner, "Try ..." hint) — startup is DONE; a busy-loop runs behind an idle-looking UI. The
busy profile after the fixes: **~87% pool thunks + ~12% app code**; hot fn = mem-source `bzhi`
(a_src=OPND_MEM Swiss-table probe loads — minspill declines ALL memory operands) + vector
group-scan ops in full-spill thunks; the hot leaf chain recurses through one static frame
(+0x37cee8b), i.e. a bytecode/regex-interpreter-shaped loop over string data.

**5. WALL-TIME NULL RESULT (proxy): 3×3 TTIDLE A/B (HEAD-default vs fixed+MINSPILL=1, 300s
cap) = ALL `TTIDLE=none`, totalcpu ≈303s both arms.** The isolated-HOME sustained spin never
ends ≤300s in EITHER arm, with or without creds copied in. So the 300s window cannot
distinguish "never ends" from "ends 40% sooner at 20+ min" — **time-to-idle at this cap is a
DEAD metric for this repro**. Meanwhile per-iteration progress (same-mode ophist vector-op
marker counts) was ~1.25–1.4× higher under MINSPILL=1 — iterations got cheaper; the loop just
runs more of them. Open fork: (a) loop is astronomically-work-bound (fix helps duration, just
invisible ≤300s), or (b) loop is condition/time-bound (per-op speedups can NEVER shrink it —
find and fix the CONDITION instead). Deciding experiment queued: identify the loop's JS-level
work (lldb string-data probe at the hot site; `--cpu-prof`/`--cpu-prof-md` argv REJECTED by
2.1.185 — the earlier "binary recognizes it" note is wrong for argv).

**6. RECURRENCE TEST (dense FAULTSNAP, 90 samples over 90s): leans WORK-BOUND, ~1–2 sweeps.**
The scanned SOURCE pointer (r0) spread across **63 distinct builtin-module addresses of 90 samples**;
string-pointer addresses recurred mostly 2× (a couple 4–8×) — i.e. the loop sweeps a LARGE set of
distinct Bun builtin-module sources ~1–2 times in 90s, NOT a tight re-scan of a few. Consistent with
a big finite compile/link sweep (work-bound) rather than a tight condition loop — though "re-sweeps
the whole set repeatedly" (condition-bound) isn't fully excluded (the 2× recurrences = ~2 passes).
The fault STREAM is 76/90 dominated by ONE still-unresolved site: **fn B tzcnt `+0x2f1e0c4`** (the
18.5 KB interpreter-shaped fn whose jump tables the new resolver deliberately leaves declined because
its table base is `lea`'d far from the dispatch, outside the 3-insn lookback). But post-fix that fault
overhead is ~0% of busy samples — the 87% is pool-thunk EXECUTION (mem-source `bzhi` Swiss-table
probes + vector group-scan), which is the real remaining cost.

**BOTTOM LINE (2026-07-02): the two DEFECTS are fixed (crash + fault storm); the residual spin is a
large volume of LEGITIMATELY-emulated JSC compile/link hashing.** Per-op lowering makes each op ~1.3×
faster but the work VOLUME dominates. The two remaining levers, in priority: (a) **lower the
mem-source `bzhi` + vector group-scan ops** (the 87%) into native thunks — minspill currently DECLINES
all memory operands, so the Swiss-table probes still take full-spill thunks; this is the biggest
un-pulled avxemu lever and directly attacks the 87%. (b) settle work-vs-condition definitively (does
the module sweep re-run? if so, find why JSC re-links). Fn-B jump-table resolution (extend the
resolver to find a non-adjacent `lea rB,[rip]` base with a bounded unclobbered-span proof) is polish,
not the nut — it removes the last ~1-2% handler overhead, not the 87%.

## ★★★ TIER BUILT (isolated-correct) but 2 REAL-BINARY BLOCKERS + a CONFOUNDED METRIC (2026-07-01 late)

The full register-resident (minspill live-register) BMI2 tier is BUILT and differentially green in
ISOLATION, but real-binary integration exposed problems the isolated test could not see. Durable
findings:

**FRUITFUL — the tier is built + isolated-correct.** avxemu branch `fix/avxemu-on-upstream`,
HEAD `eb2793c`. Minspill live-register lowerings for the whole BMI2 tier (tzcnt `2d02e82`,
shrx/sarx/rorx `b236d0e`, bzhi `2b805bb`, blsr/blsi/blsmsk `0f72cdc`, andn `bc27662`, mulx `eb2793c`;
+ native-block mulx `a22d5c1`). Each is differentially green vs `bmi_exec` in `test/minspilltest.c`
(hermetic, runs on the no-AVX2 target); `bmi_exec` itself is hardware-green on oracle-air (`build.sh`
[3][4]). Dev loop is fully local (edit → build dylib → `minspilltest`).

**BLOCKER 1 — mulx minspill CRASHES the real binary (SIGILL).** Bisected decisively (rebuild dylib
from each commit, run the real binary under isolated HOME with `AVXEMU_MINSPILL=1`, watch for early
exit): through-andn `bc27662` spins clean 9 s @ 99%; +mulx `eb2793c` → `EXC_CRASH (SIGILL)` on the
JSC "libpas scavenger" thread at ~2 s, in the anonymous RWX thunk pool (`rip` outside the dylib
image), OPHIST TOTAL=0. **NOT a pool overflow** (still crashes with `avxemu_pool_alloc` bumped
256→1024). The other 11 ops ran clean on the real binary during the bisect. Root cause is in
`emit_minspill_mulx` for some operand/register combination real `decode.c` produces that the
hand-built `minspilltest` decodes don't. (`decode.c:282` MULX: `dst=vvvv, bmi_dst2=reg, b_src=b_rm,
bmi_s1_rdx=1`; `a_src` left memset-0.) FIX PATH: lldb-catch the SIGILL → exact faulting instruction →
patch the emitter; then add a real-decode-driven case to minspilltest.

**BLOCKER 2 / RULED-OUT METHOD — a single-op OPHIST milestone is NOT a valid cross-run metric,
because the spin's bimodality is OP-MIX-LEVEL (not just total-work).** The "small burst" mode is
`vpbroadcastq`-rich (~10% of ops); the "sustained" mode is `vpbroadcastq`-POOR (79.5 K of 10.5 B
ops = 0.0008%). So `cputime-to-N-vpbroadcastq` compared a MINSPILL=1 run that fell into sustained
mode (22 min to 79 K) against a MINSPILL=0 burst-mode run (100 K in 4.2 s) — an artifact of MODE,
not the intervention. The earlier shlx-milestone A/B (RULED-OUT "SINGLE-OP … AMDAHL" below) was
stable at ±0.3% only because those runs happened to be same-mode; do NOT assume that holds. **A valid
measurement must PIN the mode or use a DETERMINISTIC non-spin workload** (e.g. time
`AVXEMU_FORCETRAMP=1 [AVXEMU_MINSPILL=0/1] claude --help`).

**LESSON (durable) — the hermetic minspilltest is necessary but NOT sufficient.** Hand-built decoded
structs miss what real `decode.c` produces + real execution contexts. **Validate thunks against the
REAL binary via `AVXEMU_FORCETRAMP` output-equivalence** (build.sh step [8b] already does
`AVXEMU_FORCETRAMP=1 claude --help` output == native) BEFORE trusting a lowering. A wrong FLAG (not
just a crash) can send the app into a runaway — precisely the failure mode the confounded run may
have hinted at. NEXT once mulx is fixed: run `AVXEMU_FORCETRAMP=1 AVXEMU_MINSPILL=1 claude --help`
output==native on target AND oracle-air as the correctness gate, THEN do a mode-pinned / `--help`-timing
measurement.

**Harness added this session** (in `scripts/`): `rate2.sh` (op-milestone A/B — but see the
confound above), `rate_ab.sh`, `burst_ab.sh` (exit-based — invalid, spin doesn't exit), `pyte_hold.py`
(hold a spin alive for probing), `claude_185_cpuprof` (BUN_OPTIONS cpu-prof launcher). Safe-isolation
protocol validated live: throwaway `HOME=/tmp/spin_home` (symlinked infra + copied `.claude.json` +
copied creds — never touches the real `~/.claude.json`), exact-PID teardown only.

## ★★★ SINGLE-OP INTERVENTIONS ARE AMDAHL-INVISIBLE (2026-07-01) — measure ACROSS-THE-BOARD only

**`mulx` native-block A/B = FLAT, and this was predictable.** Built + oracle-verified a native
register-resident lowering of `mulx` (the 35% op) via the scalar-BMI native-block path (removes the
per-op C `bmi_exec` **math**; the tt2 full-spill frame is UNCHANGED). A/B on the sustained isolated-
HOME spin, metric = **CPU-time to reach 1.5M `shlx`** (a still-emulated op, counted in BOTH
conditions — bimodality-robust; see below):
- **NATIVE=0** (mulx via C math): 3.35 / 3.34 / 3.35 s → **3.347 s**
- **NATIVE=1** (mulx via native block): 3.34 / 3.34 / 3.33 s → **3.337 s**  (**−0.3%, flat**)

**Why flat, and why it does NOT refute the per-op-frame hypothesis:** the hot loop runs ~7 BMI ops
per iteration, each paying the same per-op frame (spill/dispatch/reload). Removing ONE op's math
(mulx here) — or ONE op's spill (shlx, the old "minspill REFUTE") — leaves the other ~6 ops' full
cost, so the loop barely moves **even if the frame IS the cost**. This is Amdahl: single-op
interventions cannot reveal the frame cost. **⇒ Both prior single-op flats (mulx-math now, shlx-spill
before) are UNINFORMATIVE, not refutations.** The only informative experiment is removing the per-op
frame for the WHOLE dominant tier at once.

**DECISION: go register-resident (minspill live-register = removes spill AND inlines math) across the
ENTIRE BMI2 tier** (mulx/shlx/shrx/sarx/bzhi/tzcnt/blsr/andn/rorx), THEN measure the loop:
- collapses → the per-op frame WAS the cost (fix found); build/ship the tier.
- still flat → memory/volume-bound; per-op optimization is dead (decisive negative → redirect).
Do NOT measure per-op along the way (Amdahl-invisible); measure once the tier is covered.

**Metric that WORKS (record for reuse): CPU-time to a fixed count of a still-emulated op.** The spin
is bimodal in TOTAL work (a run does ~15M ops OR ~900M+ ops — a ~60× swing) but the **per-iteration
rate is rock-stable** (3.33–3.35 s to 1.5M shlx, ±0.3%). So a fixed-milestone CPU-time metric is
immune to the total-work bimodality and cleanly detects a real effect. (`scripts/rate_ab.sh`.)
CAVEAT: with NATIVE=1 a lowered op bypasses the OPHIST counter — so pick the milestone op from the
STILL-emulated set (shlx works while only mulx/lzcnt are lowered; re-pick as the tier grows).

**CORRECTION to the prior "isolated-HOME = finite burst" entry below:** the isolated throwaway HOME
DOES reproduce the SUSTAINED spin (observed a run at 14:47 CPU / 99%, never idling) — the earlier
"finite ~15M-op burst then exits" was one mode of the bimodal behavior (or premature teardown during
an idle dip). So the isolated-HOME proxy is FAITHFUL to the sustained spin, not merely a burst — good
(still a proxy per the user; confirm in real-project context before shipping). The clean-exit-burst
mode still happens sometimes.

## ★★ REPRO CHARACTERIZATION (2026-07-01): isolated-HOME = finite BURST, not the sustained spin

Setting trust via a **throwaway `HOME`** (`/tmp/spin_home`, symlinked infra, own `.claude.json` copy
+ optional cred copy — the SAFE isolation that never touches the user's real `~/.claude.json`; see
`[[no-broad-pkill-claude]]`) does NOT reproduce the sustained never-idle spin. Under `trusttest` it
does a **finite ~15–17M-op burst** (identical BMI2/mulx Swiss-table op-mix) then **goes idle / exits
cleanly** — never observed >~0.3% CPU on periodic samples; the ops fire in a quick burst. True both
logged-out AND logged-in (cred copy). ⇒ the **sustained "never idles in 600s" spin depends on real-
`HOME`/project DATA** (history/projects/statsig/larger project than the 1-file `trusttest`), not just
trust+creds. Reframes the sustained spin as a **much larger finite burst scaled by data volume** —
consistent with "finite but huge."

**Consequences for methodology:**
- The isolated-HOME **clean-exit burst** is our **live PROXY metric** (wall-time + OPHIST op-count to
  finish startup): safe (full isolation, exact-PID teardown, clean exit) and measurable — unlike the
  wedged never-idle spin. **CAVEAT (user, 2026-07-01): it is a PROXY.** Any fix that helps the burst
  MUST be re-confirmed afterward in the ORIGINAL context (real-`HOME` sustained spin) before we
  believe it. Do not declare victory on the proxy alone.
- Bonus: the clean-exit burst would also flush a `--cpu-prof-md` profile (the thing the wedge blocked
  earlier) — available if we later want JS function names.

## ★★ STRATEGY RULED-OUTS (2026-07-01, user-confident) — why the fix must be avxemu native lowering

Three would-be escapes are CLOSED. This is why the chosen path is "make avxemu run the dominant
ops natively, across the board" (HEROIC-OPTIONS Tier 1b), not a config/version/upstream dodge:

1. **No JSC/Bun flag disables the AVX2/vectorized-codegen path.** The HEROIC-OPTIONS §1a "cheap
   flag" (a `JSC Options::useAVX`-style env / Bun passthrough that forces SSE-baseline codegen or
   caps the JIT tier) was investigated and **does not exist**. We already pass
   `JSC_numberOfGCMarkers=1`, so the channel works — there is simply no option that turns off the
   BMI2/AVX2 hash-map/string path. The `(H-JSC-flag)` probe above is therefore closed, NOT open.
   (User-confident from prior investigation; do not re-run a `JSC_*` sweep expecting a win.)
2. **Upstream will not fix this use case.** Counting on Anthropic/Bun to care about no-AVX2
   pre-2013 Macs is out of our hands and not a plan. (= HEROIC-OPTIONS Tier 4 DEAD.)
3. **Pinning an old version (2.1.179 / Bun 1.3.14) is NOT a durable solution.** It's a real
   *diagnostic anchor* (179 doesn't spin → located the 1.3.14→1.4.0 boundary) and a temporary
   escape, but not the goal: Anthropic reaps old versions and the auto-updater drags forward.
   Same for clode/Node-as-daily-driver. (= HEROIC-OPTIONS "DEAD" list.)

⇒ With config/upstream/old-version all closed, and P0 showing the dominant ops are **register-only
BMI2 in static `__TEXT`, trampoline-dominated** (not volatile JIT), the routing diagnostic points at
**Tier 1b: eliminate the AVX2 by lowering those static sites to native register-resident SSE/scalar,
across the board** (extend avxemu Milestone-B native codegen from its current 8 vector ops to the
full dominant tier). See `docs/superpowers/plans/2026-07-01-spill-vs-math-vs-memory-factorial.md`.

## ★★★★ ATTRIBUTION CORRECTION (2026-07-01 later): the hot `<unknown binary>` frames ARE avxemu spill thunks — the "0.007% app-side" sample was MISATTRIBUTED. avxemu layer is BACK in play.

**What's SAME vs the old abandoned per-op-spill plan, and what's genuinely NEW.** We spent weeks on
"per-op trampoline spill" (shrink the thunk, reduce thunk count = the minspill work), then ABANDONED
the whole avxemu layer on the "libavxemu = 1/15013 = 0.007%, app-side 99.99%" sample. This session
shows **that sample was misattributed** — the mechanism is the SAME (the `tt2` full-spill thunk), but
the REASON we abandoned it was an artifact.

**Live evidence (lldb attach to a spinning 2.1.185, this session — not a noisy sample, structural):**
- Main-thread backtrace: **frame#0 = `0x1141b6bde` (JIT-looking `<unknown binary>`)**, **frame#1 =
  `0x256eaf5` (fn 44061, the rope/UTF-16 resolver)**, **frames#3-10 = `0x37cee8b` (fn 67339, the JSC
  bytecode interpreter, recursive)**. So the chain is: JSC interpreter → JIT stub → rope resolver
  `0x256eaf5` → the `0x1141b6xxx` frame → emulation.
- **Disassembly of that `0x1141b6xxx` frame = avxemu's full-register-spill thunk**, NOT JS: save all
  16 GPRs to `0x200(%rsp)+`, `pushfq;popq;mov` the flags, `andq $-0x10,%rsp` align, `callq *(%rip)`,
  then reload all 16. That IS `tt2`.
- **The indirect call target resolves into libavxemu:** `*(0x1141b6d20)` = `0x10f5375c0`; libavxemu
  base `0x10f531000` → offset `0x65c0` = **`tramp_emulate_run+0x80`** (nm: `_tramp_emulate_run` @
  `0x6540`). Airtight: the hot anonymous pool is avxemu's spill thunks calling the emulator.

**WHY the old sample read 0.007%:** avxemu emits its thunks into an **anonymous RWX pool**, which
`sample`/lldb tag as **`<unknown binary>`** (not attributed to `libavxemu.dylib`). The 0.007% counted
only dylib-tagged frames and so **undercounted emulation and misread the thunk pool as "JIT'd JS /
the app's own hot loop."** Corrected self-time this session (3 stable samples): thunk pool ~1500 +
`avxemu_emulate` ~690 = **~58% of busy CPU is emulation machinery**; app-native rope resolver ~9%;
the rest interpreter/JIT glue. ⇒ **"avxemu is the wrong layer" is REVERSED** — the layer is dominant
in this (fault/emulate-heavy) mode.

**BUT this does NOT cleanly un-refute the minspill A/B — the tension is real, do not paper over it.**
The minspill REFUTE (shrink shlx's spill → mulx throughput flat, −0.6%) was a real experiment. It
stands. Reconciliation candidates, in order of likelihood:
1. **Coverage gap (most likely):** minspill only ever covered lzcnt+shlx. The DOMINANT ops here —
   `bmi_exec` (mulx/bzhi/tzcnt) + `vec_exec` (vector) — **still go through the full `tt2` spill**,
   never shrunk. Shrinking one non-dominant op of ~5-7 in the loop wouldn't move the rate. So the
   A/B refuted "shlx's spill is the cost," NOT "the spill is the cost."
2. **Bimodality:** the system flips between a trampolined-cheap mode and this fault/emulate-heavy
   mode; the minspill A/B may have run in the other mode.
3. **Cost-within-thunk unknown:** it may be the emulate-math or memory traffic, not the spill frame
   (spike-bench flagged a ~35× L1-hot-vs-live gap that register-residency does NOT remove).

**Also revises the oracle-air "DIVERGENCE" reading:** if it's the same ops emulated ~100×/op slower (not a
different code path), oracle-air-fast-vs-target-slow is "same path, slower per op," not "hundreds× more
work." The oracle-air profile was thin, so this is a softening, not a full overturn.

**NEXT = the factorial experiment (separate spill vs emulate-math vs memory cost for the DOMINANT
ops).** See the "SPILL-vs-MATH-vs-MEMORY factorial" plan appended below / in start-here. This settles
the minspill conflict instead of re-litigating it, and decides whether an avxemu fix (native
register-resident lowering of mulx/bzhi/tzcnt/vector) can collapse the spin — or whether the residual
(memory/fault/op-VOLUME) means the real lever is stopping JSC from emitting these ops (a JSC/engine
option) rather than making them cheaper.

**METHOD LESSON (durable):** `sample`/lldb attribute avxemu's RWX thunk pool to `<unknown binary>`.
Any "app-side vs emulation" split MUST resolve `<unknown binary>` frames (disassemble them / check the
indirect-call target against the libavxemu range) before trusting the percentages. The 0.007% error
came from skipping that.

## ★★★★ ROOT-CAUSE BOUNDARY FOUND (2026-07-01): the regression = the Bun engine bump **1.3.14 → 1.4.0**

**The 179→183 regression boundary EXACTLY coincides with the embedded Bun/JSC engine version bump.**
Read the Bun version string out of the three compiled binaries in
`~/.local/share/claude/versions/` (`grep -aoE 'Bun v1\.[0-9.]+'`, byte-safe — old `strings` chokes
on the patched Mach-O of 183 with "unknown load command 6"):
- **2.1.179 → Bun v1.3.14** (`1.3.14+2a41ca974`) — **does NOT spin**
- **2.1.183 → Bun v1.4.0** (`1.4.0+324c5f012`) — **FIRST spinning version**
- **2.1.185 → Bun v1.4.0** (`1.4.0+324c5f012`, same commit) — still spins
Binary sizes corroborate a runtime swap (not just +JS): 179 = 229 MB, 183 = 223 MB (−5.6 MB),
185 = 224 MB — 183 is SMALLER than 179 despite +212 KB more JS ⇒ the embedded Bun runtime changed.

**This is the "same JS, different engine" hypothesis, now CONFIRMED by two independent lines:**
1. Static RE (subagent, 2026-07-01): the startup JS is **structurally identical** 179→183 — the only
   diffs are added telemetry (`tu("skills_sync_wait_ms"/"qe_system_prompt_ms"/…_ms)` wrapping
   PRE-EXISTING logic; startup phase markers `run_entry…stdin_listen_started` byte-for-byte the same).
   Everything genuinely new in 183 (powerups UI, mantle probe, CCR agent-proxy + system-CA trust,
   remote-headless, inner REPL tool, team-memory hook) is **gated on remote/CCR/non-Anthropic
   provider/on-demand tool** — none run at local trusted-project startup. So NO new JS startup loop.
2. The engine version bump above lands precisely on the 179(ok)/183(spin) boundary.

**⇒ The runaway is Bun 1.4.0's JSC/WebKit engine executing a PRE-EXISTING string-heavy startup path
(matches the native disasm: JSC bytecode interpreter + rope/UTF-16 string resolver, emulation 0.007%)
pathologically slowly ON THE OLD MAC — where Bun 1.3.14 did the same work fine.** The fix lever is
the ENGINE / its environment, NOT the JS bundle and NOT avxemu.

**Why old-Mac-only (Bun 1.4.0 is fine on oracle-air/macOS-15/AVX2 — verified earlier). Still 3 co-varying
env diffs (unchanged from before): no-AVX2, macOS 10.9, and the compat shim libs.** New leading
sub-hypotheses to test next, most actionable first:
- **(H-ICU) The ICU shim.** String work (UTF-16/normalize/collation) routes through the Mavericks
  `libicucoreWrapper.dylib`. If Bun 1.4.0's JSC uses ICU more/differently than 1.3.14, the wrapper
  could handle it pathologically (slow, or triggering rescans/retries) → a string-heavy native spin
  that only exists on the old Mac. This points at OUR shim (fixable). TEST: dtrace/instrument ICU
  call volume during the spin; or vary/deepen the ICU wrapper.
- **(H-JSC-flag) — RULED OUT (see "STRATEGY RULED-OUTS" below).** No JSC/Bun flag disables the
  AVX2/vectorized-codegen path; the flag hunt is closed.
- **(H-phase) Localize the runaway PHASE.** 183 added a full `tu(..._ms)` timer suite
  (`node_boot_ms, settings_load_ms, hooks_init_ms, mcp_connect_ms, skills_load_ms,
  skills_sync_wait_ms, qe_system_prompt_ms, permission_context_ms`, …) + `iC`/`QW` phase markers.
  Surface them (debug/telemetry log, or a `--debug`/env channel) on the spinning old Mac: the LAST
  emitted `before_*` marker / the `*_ms` that never completes pinpoints the exact runaway phase.
  Top suspects from RE: system-prompt assembly (`l1o`→`Wc([...])` dedup/join) and skills load/parse.

**METHOD WIN:** the fastest confirmation of "engine, not JS" is the version-string diff above — do it
FIRST on any future regression. Do NOT keep bisecting the JS bundle for a new loop (there isn't one).

## ★★★ JS-LEVEL PROFILER CHANNEL — FOUND (2026-07-01): `BUN_OPTIONS` DOES work; but the SPIN can't be flushed (wedged)

**FRUITFUL (reverses a prior dead-end):** Bun's built-in CPU profiler CAN be turned on for
the compiled standalone, and it emits a **markdown profile with JS function names + source
locations** (`/$bunfs/root/src/entrypoints/cli.js:LINE`). The working channel is the
**`BUN_OPTIONS` env var**, which the Bun runtime reads at startup:
```
BUN_OPTIONS="--cpu-prof-md --cpu-prof-dir=/tmp/prof --cpu-prof-interval=2000"
```
- **Validated:** `BUN_OPTIONS="--cpu-prof-md --cpu-prof-dir=/tmp/prof" <launcher> --version` wrote
  `/tmp/prof/CPU.*.md` (187 KB, 617 functions; top frames named — `WeakSet`, `(anonymous)` at
  `cli.js:11`, `_parse`/`jre`/`Ftd` at `cli.js:70/557`, etc.). Format: a "Hot Functions (Self
  Time)" table with Self%/Total%/Function/Location. Exactly the artifact we wanted.
- **WHY the prior "BUN_OPTIONS is scrubbed/ignored" was WRONG:** the binary's `BUN_OPTIONS`
  scrub-list entry is the env Bun strips **from child processes it SPAWNS** (so `node`/tool
  children don't inherit debug flags) — NOT what its own runtime ignores at startup. The app
  itself relies on the runtime reading `BUN_OPTIONS`: the bundle contains
  `export BUN_OPTIONS="--smol${BUN_OPTIONS:+ $BUN_OPTIONS}"` (it appends `--smol`, preserving any
  pre-set value — so our flags survive the app's own re-set).
- Launcher `scripts/claude_185_cpuprof` now sets this (was briefly a wrong leading-argv variant).

**RULED OUT — leading-argv channel (the prior note's hoped-for approach):** passing
`--cpu-prof-md` as **direct leading argv** to the binary FAILS — the Claude CLI's own arg parser
(commander) rejects it: **`error: unknown option '--cpu-prof-md'`**. A compiled standalone does
NOT consume Bun runtime flags from argv; they fall through to the app, which errors out and exits.
So "pass `--cpu-prof-md` as direct leading argv + clean /quit" (start-here's suggested move) is
**refuted**. Use `BUN_OPTIONS`.

**RULED OUT — flushing the SPIN by exit or signal (the blocker):** the profiler only writes on a
**clean process exit**, and the startup spin **wedges the main thread** so no clean exit is
reachable:
- Interactive `/quit` mid-spin is never processed (baseline `pyte_quit.py`: `graceful-exit=False`
  after 20 s while pegged at 100%).
- **SIGINT and SIGTERM are both swallowed** — child stays alive 40 s+ and keeps spinning at 101%
  (tested on the live profiler-active pid). Never SIGKILL (drops the flush).
- Combined with the standing fact that the **spin never idles in any known time (600 s+)**,
  "wait for natural completion → /quit" is also not viable in a tractable window.
⇒ We can turn the profiler ON, but cannot get the buffered samples of the *spinning* process to
disk by any exit/signal path while it's wedged.

**RULED OUT — inspector/CDP via `BUN_OPTIONS`:** `--inspect` / `--inspect-wait` through the
now-working `BUN_OPTIONS` channel opens **no listener and prints no banner** (no port on 9230,
0 bytes). The standalone's remote inspector is non-functional (matches the earlier `BUN_INSPECT`
env result). So there is no out-of-band CDP route to drive `Profiler.start/stop` and pull the
profile without a process exit.

**No callable flush symbol:** the binary is stripped (843 syms, none matching `prof`/`cpu`), so
there's no exported Bun `cpuProfileEndAndWrite`-type routine to invoke directly.

**RULED OUT — lldb-forced `exit(0)` flush (tested 2026-07-01, the risk above was REAL):** attached
old Mavericks lldb (320.4.160, no `--batch`; drive via stdin `process attach --pid N` / `expr
(void)exit(0)`) to the wedged profiler-ON pid. The process **exited cleanly (status 0)** but wrote
**NO profile anywhere** (searched /tmp, project dir, $HOME; the earlier clean-JS-exit --version
profile is intact for contrast). ⇒ Bun's cpu-prof writer fires on the **JS-level exit sequence**
(a `process`-exit path that drains the event loop), NOT a libc `__cxa_atexit` hook — so a libc
`exit()` from lldb bypasses it. The whole **exit/signal family is now exhausted** for flushing a
wedged process: /quit (blocked), SIGINT/SIGTERM (swallowed), lldb `exit(0)` (exits but no flush).
The profile can only be flushed when the JS event loop reaches its OWN clean exit — i.e. when the
spin COMPLETES.

**NEXT (pick one), given the profiler works but only a JS-clean-exit flushes it:**
- **(B) Patient full-completion, ideally via `-p` print mode:** `BUN_OPTIONS=<profiler> claude -p
  "hi"` in the trusted project runs full startup (triggering the spin), and when it finishes it
  **exits on its own via the JS path → flushes** — no interactive /quit, no wedge-teardown. Run in
  background and wait however long the spin takes (>600 s, possibly much more; the "finite compute"
  claim is inferred from AVX2-hw doing it in seconds, NOT directly observed to terminate under
  emulation — so this could be very long or effectively unbounded). Interactive variant: profiler
  ON + idle-detection + /quit, same idea. This is the only route that yields a COMPLETE spin
  profile with JS names.
- **(D) lldb live-stack symbolication (no exit needed):** attach lldb to the live spinning pid and
  map the JSC `CodeBlock` at the live PC to a JS function name (walk JSC runtime structs from the
  frame). Hard on this ancient lldb without JSC debug symbols, but needs no flush and no
  completion. Complements the native disasm already done (`0x256eaf5` rope resolver / `0x37cee8b`
  interpreter).
- **(C) Static RE of `cli.js`** for the string-heavy startup path (the `cli.js:70/557` regions the
  --version profile already fingerprints; the 179→183 diff; skills_sync / qe_system_prompt leads).

New tooling this session: `scripts/claude_185_cpuprof` (BUN_OPTIONS profiler launcher),
`scripts/pyte_quit.py` (clean-/quit driver — proves the wedge), `scripts/pyte_spin_prof.py`
(spin capture + signal-flush attempt — proves SIGINT/SIGTERM don't flush).

## ★★ GATE RESULT (2026-06-30 late) — lzcnt gate INCONCLUSIVE; OP ATTRIBUTION was WRONG

Phase 1a built a correct, silicon-validated minimal-spill live-register **lzcnt** thunk
(avxemu commits 8bc36b3..d965180; 70-case differential green on both the no-AVX2 target and
AVX2 oracle-air; adversarial review caught 2 real Criticals — PF/AF pushfq-ordering and
red-zone/rsp-operand). Then the trusted long-window A/B (isolated `/tmp/avxemu_natslice` dylib,
trust verified, `$MF` untouched, trusttest project, AVXEMU_NATIVE=1):

- **AVXEMU_MINSPILL=1 vs =0: NO difference** — both peg ~101% CPU for the full window, identical
  static screen. BUT this is **structurally inconclusive, not a refute.**
- **Why: the AVXEMU_OPHIST C-emulated op histogram for THIS spin is dominated by the BMI2 scalar
  tier, NOT lzcnt/vpbroadcastw.** Out of 10.44M C-emulated ops:
  **mulx 3.82M (36.6%) · shlx 2.60M (24.9%) · bzhi 1.21M (11.6%) · tzcnt 0.96M (9.2%) ·
  blsr 0.49M (4.7%) · andn 0.44M (4.3%) · shrx 0.17M (1.6%) ⇒ ~92.9% scalar BMI2.**
  **lzcnt = 81 (0.0008%). vpbroadcastw = 0 (absent).**
- So the plan's premise ("lzcnt 46.8% + vpbroadcastw 46.8% = 93.6%") **does NOT hold for the
  .185 startup spin** — that attribution was from a different/UTF-8-transcode context. A
  minimal-spill lzcnt thunk cannot move a spin it is 0.0008% of; the A/B result says nothing
  about the spill hypothesis.

**Implications (do NOT mis-read as "spill refuted"):**
- The per-op-spill hypothesis is **still untested** — we tested the wrong op. It is neither
  confirmed nor refuted.
- The real lever for the startup spin is the **scalar BMI2 tier (mulx/shlx/bzhi/tzcnt/blsr/
  andn/shrx ≈ 93%)**, currently C-emulated through the full tt2 spill EVEN with NATIVE=1
  (Milestone B's native set never covered these). mulx is multiply-heavy ⇒ the spin looks
  bignum/crypto/hash-bound, not text-transcode.
- **NEXT: re-target the minimal-spill gate at mulx + shlx (61.5% combined).** The Phase-1a
  infrastructure transfers directly: the harness (`test/minspill_harness.s`/`minspilltest.c`),
  the emitter pattern (`emit_minspill_lzcnt` + `gb_*`/`nb_*` byte helpers, red-zone + flag
  discipline), the `AVXEMU_MINSPILL` gate, and the trusted A/B protocol. Each scalar BMI2 op =
  live-register lowering + minimal save + oracle (`bmi_exec`) + A/B increment. shlx/shrx/sarx
  (no flags) are the simplest; mulx (128-bit product, two dests, no flags) is the biggest win.
- Methodology win locked in: **read the live AVXEMU_OPHIST histogram FIRST to pick the gate op**
  — don't trust a stale attribution. (This is exactly the prior failure mode the brief warns of.)

**★ GATE VERDICT: REFUTE per-op SPILL (2026-06-30 late, rigorous 3×3 A/B).** With the spin
multi-minute (does NOT idle within 600s — fixed-but-huge compute, not an infinite loop;
AVX2 hw does it in seconds), time-to-idle is unmeasurable, so the metric is **mulx throughput
in a fixed 120s window** (mulx is C-emulated in BOTH conditions → a bottleneck-faithful progress
meter). Result (mulx ops / 120s, trust-verified, isolated dylib, `$MF` untouched):
- **OFF (MINSPILL=0):** 3.93M / 3.95M / 3.82M → mean 32,498 mulx/s
- **ON  (MINSPILL=1):** 3.83M / 3.91M / 3.89M → mean 32,309 mulx/s  (**−0.6%, statistically flat**)
- Firing confirmed: shlx C-emulated 2.61M→0.99M (~62% of shlx → native minimal-spill thunks).

**Removing the per-op spill frame + C-dispatch call for ~16% of all emulated ops gave ZERO loop
speedup.** Together with the prior native-math result (native-ON ≈ native-OFF), **neither the
per-op math NOR the per-op spill is the dominant cost** — both per-op levers are now spent.
⇒ The leading "per-op spill" hypothesis is **REFUTED.**

**★★★ RE-PROFILE RESULT (2026-06-30, `sample` of the live spinning 2.1.185 pid): the spin is
APP-SIDE, NOT emulation. The avxemu strategy is RULED OUT as the startup fix — definitively.**
A trust-verified `sample` of the actual spinning process (100% CPU, main thread, 15013 samples
over 20s) shows:
- **libavxemu.dylib: 1 sample / 15013 = 0.007%** (one `avxemu_tramp_dispatch_bmi` hit). The
  whole emulation layer is COLD.
- **2.1.185 app binary: ~100% of samples.** Heaviest leaf = **`2.1.185 + 0x256eaf5` (atos:
  unnamed, +85; binary is stripped, 843 syms) = 14057/15013 = 93.6%**, reached through a deep
  self-recursion at **`2.1.185 + 0x37cee8b`** (Bun/JSC runtime C++), with secondary `<unknown
  binary>` JIT'd-JS regions (`0x11fbf9xxx`). All worker/Bun-pool threads are SLEEPING (cvwait).
- So the 10M+ OPHIST emulated ops are real but wall-time-negligible (~1 µs each, trampolined):
  the earlier "~23K cycles/op" was a miscalc (it wrongly assumed the 100% CPU was IN emulation).

**This CONFIRMS the earlier "app-side reframe" (which start-here had dismissed as an
over-correction) — now with STRONG evidence: a rigorous emulation-hypothesis REFUTE (the
minimal-spill A/B) PLUS a clean PC profile, not a single second-guessed sample.** Emulation
optimization of ANY kind — minimal-spill, native codegen, or Phase 2 region translation —
cannot fix a spin that is 99.99% the app's own hot loop. **avxemu is the wrong layer.**

**NEXT (app-side):** identify the hot loop. The fix lives in the app, not avxemu:
- Symbolicate / RE `2.1.185 + 0x256eaf5` (hot leaf) and the `0x37cee8b` recursion — Bun/JSC
  runtime C++ (clode is the RE tool). Candidate natures: a GC/heap-walk recursion (note the
  launcher already sets `JSC_numberOfGCMarkers=1`), a JSC JIT-compile loop, or a Bun-internal
  data-structure walk that scales pathologically.
- Cross-check the 179→183 regression leads already in this doc (new-in-183 timers
  `skills_sync_wait_ms`/`qe_system_prompt_ms`/`tengu_repl_inner_watchdog`; the +206KB cli.cjs
  diff) and the JIT'd-JS `<unknown binary>` frames.
- WHY no-AVX2 only (AVX2 hw is fine): the app hot loop's iteration count/behavior must depend
  on AVX2 availability (e.g. a feature-detect fallback, or a busy-wait on slow-emulated work) —
  but the *time* is in app code, so the lever is the app's loop, not the emulated op cost.

**Do NOT build more avxemu (no mulx thunk, no Phase 2).** The minimal-spill infra (lzcnt+shlx,
silicon-validated, committed e1f4cf4) stands as correct, reusable emulation-speedup work, but
it is not the startup fix.

**FEATURE-DETECTION FALLBACK also REFUTED (2026-06-30, cpuid-completeness A/B).** Tested the
"interaction" sub-hypothesis: under emulation the app sees an INCOMPLETE feature set and picks a
scalar `no_avx2` fallback. libavxemu's default faking advertises AVX2+BMI but NOT FMA (verified:
raw cpuid under the dylib = `avx2=1,bmi=1` but `fma=0`), and the binary is a Haswell build
(AVX2+**FMA**+BMI) — a plausible "x86-64-v3 incomplete → fallback" trigger. A/B (same harness,
trusted, isolated dylib): **DEFAULT faking vs `AVXEMU_CPUID_SET=all`** (completes the set —
verified it flips `fma=1`, plus f16c/movbe). Result: **identical spin** (both peg 180s, static
screen, never idle) and **identical executed-op mix** (mulx 4.01M vs 4.02M, shlx 2.59M both,
TOTAL 10.85M both). ⇒ **the app does NOT branch on the advertised cpuid features** (avx2/bmi/fma/
f16c/movbe); the FMA-gap / feature-detect-fallback mechanism is dead. Every emulation-side lever
now tried — per-op math (native), per-op spill (minspill), AND feature advertisement — leaves
the spin and the op mix unchanged.

**★★★ COMMENSURATE oracle-air COMPARISON (2026-07-01) — DIVERGENCE, not slowdown; + login ruled out.**
Set up a valid cross-machine test: fetched UPSTREAM 2.1.185 for oracle-air (macOS 15, AVX2) via the
official installer URL (`downloads.claude.ai/claude-code-releases/2.1.185/darwin-x64/claude`,
checksum-verified), repointed oracle-air's `claude` symlink to it, and **verified `__text` is
byte-identical to the target's Mavericks-patched 2.1.185** (`otool -s __TEXT __text | shasum` =
`9a18a970…` on both) — so `0x256eaf5` is the same function and the comparison is code-valid.
Controlled the confounds this exposed:
- **LOGIN is NOT the trigger.** The target's screens showed it spins while *logged in* (Claude
  Max); oracle-air over ssh showed "Not logged in" (a locked-keychain artifact — oracle-air uses the macOS
  keychain, target uses a file cred). Decisive test: ran the target **logged OUT** (throwaway
  HOME with trust+onboarding but NO credentials file) → it **STILL pegs 101% for 120s**. So the
  spin is independent of auth state. (Rules out the "logged-in gateway/sync crypto loop" idea.)
- **cpuid feature advertisement is NOT the trigger** (prior entry: complete-faking null).
- **Result: oracle-air native startup = ~1.5 CPU-seconds, idles in 9s. Target = 600s+, never idles.**
  The spin is SCALAR app code (emulation 0.007%), which runs at ~native speed on both (Ivy vs
  Broadwell scalar ≈ ~2×). If both ran the same path the target would finish in ~3s. It doesn't —
  it does **hundreds of times more WORK.** ⇒ **DIVERGENCE: the emulated/old environment triggers
  a heavy app code path that the native environment does not execute at all** (`0x256eaf5` absent
  on oracle-air). This is the "interaction" flavor: not pure emulation (op-speedups null), not pure
  algorithm (native is light — 1.5s), but the algorithm diverging into runaway work under the
  emulated environment.

**HONEST CAVEATS (do not over-read):** (1) the oracle-air profile SAMPLE was thin (~1.5 CPU-s to
sample) — the `0x256eaf5`-absence is weakly sampled, but the CPU-MAGNITUDE divergence is robust
on its own. (2) The comparison still has 3 co-varying env differences — AVX2-emulation, macOS
version (10.9 vs 15), and the compat shim libs (libI/libS/libc++). So "AVX2 specifically triggers
it" is NOT isolated; it could be the OS or the shims. Next work must narrow WHICH, and identify
the runaway loop (RE `0x256eaf5`/`0x37cee8b`), and test the timing-interaction idea (a slow-op
→ runaway-loop mechanism) — note minspill made ops faster with NO throughput change, which argues
against a simple time-budget loop and toward a genuinely different code path.

**DISASSEMBLY of the hot loop (2026-07-01) — it's the JSC BYTECODE INTERPRETER running
string-heavy JS (refines "app-side", not brand-new).** `lldb` disassembly of the target's
2.1.185 at the profiled offsets (static vmaddr = 0x100000000 + offset):
- **`0x37cee8b` (the recursion, hottest engine)** is a **computed-goto bytecode dispatch loop**:
  `movzbl (%r13,%r8),%eax` (load opcode byte; r13=bytecode, r8=PC) → `leaq <table>(%rip),%rsi` →
  `jmpq *(%rsi,%rax,8)` (jump through the opcode dispatch table) → `callq *%r10` (invoke a
  handler/JS fn) → `addq $0x5,%r8` (advance PC). This IS the JavaScriptCore low-level interpreter.
- **`0x256eaf5` (93.6% leaf)** is a JSC **rope/string resolver**: `testb $0x1` tag-vs-pointer
  discrimination (`cmovne`), `movzwl %cx` UTF-16, calls a sub-fn — i.e. resolving/iterating strings.
- The `<unknown binary>` frames (`0x11fbf9xxx`) are **JIT'd JS**.
⇒ The 100% CPU is **Claude's own JavaScript executing** (interpreter + JIT), doing **string-heavy**
work at startup. So the runaway lives in the JS BUNDLE, not native code — consistent with (and
sharpening) the earlier "app-side JS" reframe. NOTE: this overlaps prior findings; the genuinely
new part is "specifically the JS interpreter + rope-string resolution," which points the hunt at
*which startup JS* (clode/cli.cjs; the 179→183 diff; skills_sync / qe_system_prompt leads) and
suggests the next probe is a JS-LEVEL profile (function names), e.g. JSC sampling profiler.

**JS-LEVEL PROFILING ATTEMPTS LOG (2026-07-01) — what was tried, so it's not repeated the SAME way.**
Goal: get JS function NAMES for the runaway (native profiling only gave "it's the JSC interpreter").
- **JSC sampling profiler** (`JSC_useSamplingProfiler=1` + `JSC_dumpSamplingProfilerDataOnExit=1`
  + `JSC_samplingProfilerPath=/tmp`, graceful SIGTERM): **NO output.** Bun does not surface JSC's
  built-in sampling-profiler dump. DEAD END as-is.
- **Bun inspector** (`BUN_INSPECT=ws://127.0.0.1:9230/`): **no inspector banner / no listen.** The
  compiled standalone doesn't activate the inspector via that env the way `bun run` does. (A
  websocket/CDP client would be needed IF it listened — it doesn't via this env.)
- **`BUN_OPTIONS="--cpu-prof --cpu-prof-dir=…"`**: **no `.cpuprofile` written** (neither on the
  spin nor a `--version` clean exit). `BUN_OPTIONS` appears NOT honored for runtime flags by the
  standalone — it's literally in the binary's scrubbed-env list `ELd=[…,"BUN_OPTIONS",…]`, and the
  wrapper also force-prepends `--smol`.
- **Graceful SIGTERM to flush**: didn't help — claude likely doesn't flush a profile on SIGTERM.

**PROMISING but do it a DIFFERENT way next time:** the binary **DOES recognize** `--cpu-prof` /
**`--cpu-prof-md`** (markdown, "grep-friendly, designed for LLM analysis") / `--cpu-prof-dir` /
`--cpu-prof-interval` / `--heap-prof` (it emits `--cpu-prof-dir requires --cpu-prof or
--cpu-prof-md`). So the profiler exists; the two things to get right are (1) a CHANNEL that
actually passes the flag to the Bun runtime of a COMPILED app — NOT `BUN_OPTIONS` (scrubbed);
try passing `--cpu-prof-md --cpu-prof-dir=…` as DIRECT leading argv to the binary, or a `bunfig`,
or `CLAUDE_*`/`BUN_*` alternative — and (2) a CLEAN EXIT to flush ("write on exit"): drive the
TUI to `/quit` or a handled Ctrl-C via the pty rather than SIGKILL. `--cpu-prof-md` output is the
target. (Also untried: attaching `lldb`/`sample` and mapping the JSC CodeBlock at the live PC to a
JS function name; and the static route — RE the JS bundle/cli.cjs for the string-heavy startup
path, guided by the 179→183 diff + skills_sync/qe_system_prompt leads.)

**STATE OF THE INVESTIGATION (what's robust vs open):**
- ROBUST: the spin is app-side compute (profile: app 99.99%, libavxemu 0.007%); no emulation-side
  intervention changes it (math, spill, feature advertising all null).
- OPEN: WHAT the app hot loop (`2.1.185+0x256eaf5` leaf + `+0x37cee8b` recursion) actually is,
  and WHY it is AVX2-host-dependent. The natural cross-machine discriminator (profile oracle-air's
  native startup of the SAME path) is currently INFEASIBLE: oracle-air has only the bare 223MB binary
  — missing companion dylibs (`dyld: libI.dylib not loaded`), no `~/.claude` auth, no
  `~/.claude.json` trust, no launcher infra — so it cannot run a commensurate trusted startup.
- NEXT (pick one): (a) RE/symbolicate the hot loop `0x256eaf5` + `0x37cee8b` (clode) to identify
  the actual computation; (b) restore a WORKING claude on oracle-air (companion libs + auth + config)
  for a commensurate AVX2-vs-emulated path comparison; (c) attack the 179→183 regression directly
  (179 doesn't spin) — diff what new-in-183 code the hot path corresponds to.

**RE-AIM IN PROGRESS (2026-06-30 late, avxemu e1f4cf4):** built + silicon-validated a
minimal-spill live-register **shlx** thunk (the simplest dominant op: 24.9%, defines no flags).
384-case differential vs `bmi_exec` green on both no-AVX2 target and AVX2 oracle-air;
adversarial machine-code review = SHIP (verified red-zone/rcx-CL/aliasing discipline). Generic
dispatch (`emit_minspill_op`) now covers lzcnt|shlx behind `AVXEMU_MINSPILL`. **Firing CONFIRMED:**
a trust-verified 60s run shows C-emulated shlx drops **2.67M → 1.00M (~63% captured)** with
MINSPILL=1 (the rest are multi-op/rcx-dst/mem runs minspill declines), while mulx stays flat
(4.0M both) — so ~16% of ALL emulated ops now skip the spill frame. **Spin time-to-idle A/B
(the actual gate verdict) is being measured next** — recorded here once in. NOTE: smoke runs
show both ON & OFF peg ~101% past 150s without idling, so the spin is multi-minute; using a
time-to-idle watcher (`scripts/pyte_ttidle.py`, exits on sustained idle) to capture it.

## ★ LEADING HYPOTHESIS (2026-06-30) — per-op trampoline OVERHEAD (spill/reload), not emulation math

**The spin is the per-AVX2/BMI-instruction *handling overhead* — the trampoline frame
(spill all regs → dispatch → reload) paid for every op, every iteration — NOT the emulation
math, and NOT the app/JS.** The avxemu approach was abandoned on a *confounded* result
(native-codegen made the math native but kept the per-op spill, so it changed nothing) — that
was premature. Reopening it with the spill as the target.

**Evidence:**
- **AVX2 hardware (oracle-air, our baseline) runs .185 fine.** Same Bun, same JSC JIT, same
  app loop → the JS/JIT code is NOT the problem. The ONLY variable vs Ivy Bridge is how the
  AVX2/BMI instructions are handled. ⇒ the spin is squarely emulation-layer, and AVX2 hw pays
  **zero** per-op overhead (ops are inline) → that overhead is the entire gap.
- **native-ON ≈ native-OFF (both peg ≥240s).** Both reach each op through the SAME spill/reload
  trampoline frame; native only changed the cheap inner part (SSE vs C-emulate). Removing the
  math gave ~0 benefit ⇒ the math was never the cost; the common factor (the per-op frame) is.
- **The spike measured no-spill/register-resident at ~50–65×**, with the spill a real chunk —
  but the shipped slot-based codegen KEEPS the full spill, so it never realized that win.

**Correction to earlier "avxemu RULED OUT / ~1.5× ceiling / app-side" conclusions below:**
those are over-stated. What's actually ruled out: **emulation-MATH optimization** (measured
~0 benefit). What's the live lever, NOT ruled out: **eliminating the per-op spill/handling
overhead** (minimal-spill per-op thunks that save only what each op clobbers, and/or whole-
hot-region translation that runs ops inline with state kept in registers — no per-op round
trip). Goal: drive per-op handling cost toward the ~1-cycle hardware cost.

**Decisive test (cheap, do first):** a no-/minimal-spill handling A/B on the hot op(s) — if
per-op overhead drops toward hardware and the spin collapses, hypothesis confirmed. (Plan of
attack being written under `docs/superpowers/`.)

---

## How to read this doc: PROGRESS vs DEAD ENDS

Not everything below is a dead end. Two distinct categories — don't conflate them:

### A. Moves that ADVANCED the diagnosis (productive — these are the chain that got us here)
Each didn't *fix* startup, but each *revealed the next problem*. This is the spine of the
investigation; re-tread it only to extend it, not to repeat it.
1. **Trust-gate minimal repro** (empty trusted dir, `hasTrustDialogAccepted`) → spin is
   content-independent, trust-gated; gave a repro. (Caveat learned later: untrusted idles, so
   a dropped trust entry fakes a "fix" — verify trust before every run.)
2. **dtrace `si_addr` histogram** (instead of confounded leaf-PC) → located the actual
   faulting instruction addresses (the hot sites).
3. **Byte-level recon of the hot sites** → corrected "AVX2-vector" to **scalar BMI**
   (lzcnt/tzcnt); found the sub-5-byte "can't trampoline" structural cause; killed the
   "2nd `__TEXT` segment" and "JSC-JIT'd code" theories.
4. **Milestone A (relocation) + live A/B** → spin is **trampoline-bound, not trap-bound**
   (the 52K-sigreturn storm was the pre-trampoline era; current spin is ~0 syscalls).
5. **Register-resident micro-bench (spike)** → native codegen is ~50×/run (worth building)
   AND flagged the memory-traffic caveat.
6. **Native-codegen slice + dtrace A/B** → the first 8 vector ops were **0.15%** of the
   workload (wrong ops) — native displaced nothing.
7. **`AVXEMU_OPHIST` execution-weighted histogram** → the REAL hot ops: **lzcnt +
   vpbroadcastw = 93.6%**.
8. **Native-codegen of the real ops + trusted long A/B + PC profile** → THE reveal:
   eliminating ALL emulation does not collapse the spin; it's the **Bun-JIT'd app hot loop**
   (pure compute, emulation only ~32%, ceiling ~1.5×).
9. **clode runs .185 fine** (user) → **Bun-runtime-specific**, not algorithmic, not "no-AVX2".

**Reusable instruments this built (use these going forward):** the `si_addr` capture, the
`AVXEMU_OPHIST` op histogram, the user-PC-by-region profile, the isolated-dylib test harness
(`/tmp/avxemu_natslice` + `scripts/claude_185_natslice` + `AVXEMU_NATIVE`/`AVXEMU_RELOC`),
and the trusted long A/B protocol.

### B. DEAD ENDS — made no measurable difference (do NOT retry)
tmux; terminal capability queries (DA/XTVERSION/OSC11); the computer-use MCP; the
`libSystemWrapper` write shim; cpuid→scalar (hot code is unconditional); plugins/skills "as
the input" (bimodal noise); the kitchen-sink of `DISABLE_*`/`SKIP_*` env levers; the headless
`-p` profiler (different "grove" path); un-fake AVX2 (hangs at boot); "no SSE4 kernel to pick".
Details for each are in the sections below.

> Net: **A** is the path that localized the true bug (Bun's JIT'd 183 hot loop). **B** is
> noise to skip. The avxemu emulation work (Milestones A/B) sits in **A** as the instrument
> that exposed the real cause — it is *ruled out as the fix* but was *productive as diagnosis*.

---

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
- ~~Leading hypothesis: a **sync-wait-on-async deadlock**...~~ **REFUTED (2026-06-30):** the
  spin is **pure compute** (dense PC samples in a ~2KB JIT loop, ~0 syscalls), not a
  busy-loop *awaiting* the event loop. The deadlock framing is dead.
- **What's DONE here (do not re-tread):** the new-in-183 functions/markers ARE identified
  (`skills_sync_wait_ms`, `qe_system_prompt_ms`, `qe_plugin_skills_load_ms`,
  `tengu_repl_inner_watchdog`), +206KB diff, narrowed to `Op` = plugin-load. Re-finding them
  adds nothing.
- **What's actually OPEN (genuinely new, different axis):** *why does Bun(JSC)'s JIT execute
  that one ~2KB hot loop ~3× slower than V8/Node does the same .185 JS, as pure compute, on
  this pre-AVX2 µarch?* That's codegen/runtime-level, never explored — NOT more source-level
  function-hunting. (The earlier "read the call sites / diff 179→183 source" TODO was premised
  on the now-refuted deadlock; redo it only reframed as "find the compute loop," and weigh it
  against just intervening — we may already know enough to test a move.)

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

**CHARACTERIZATION (trusted, native ON vs OFF, dtrace — the facts to think from):**
- **It is PURE COMPUTE, not a trap storm.** Syscalls during the spin ≈ **3 per 5s** in BOTH
  arms (no sigreturn storm). **The brief's old headline "dominated by the SIGILL/sigreturn
  tax (52K sigreturn/3s)" is OBSOLETE** — that was the pre-trampoline era; the current dylib
  trampolines the hot ops trap-free, so the spin is now CPU-bound computation.
- **Emulation is a MINORITY (~32%) of the cost.** native-OFF user-PC profile: `libavxemu`
  ≈ 3171 / ~10000 samples (~32%); the Bun-JIT'd hot loop ≈ 60%+; our thunk pool negligible.
  native-ON: `libavxemu` ~0%, all time in the JIT loop, same wall time. ⇒ the absolute
  ceiling for ANY avxemu-side emulation optimization is **~1.5×** — not parity (179 idles in
  seconds; 185 spins minutes).
- **The dominant cost is Bun's JIT'd execution of one ~2KB hot loop** (anonymous JIT region,
  e.g. `0x119ceb5xx`/`0x114f611xx`, ASLR-varying), and our thunks barely register — so it is
  NOT trampoline round-trip overhead; it's the loop's ordinary compiled instructions.
- **The SAME .185 JS runs FINE on clode/Node (user-confirmed).** So it is NOT an algorithmic
  JS regression and NOT merely "no AVX2" — it is **Bun(JSC)-runtime-specific slowness**
  executing this 183-introduced loop on this pre-AVX2 Ivy Bridge (candidate causes to think
  about: JSC tier-up/deopt thrashing, an auto-vectorized inner loop JSC emits that's awful on
  this µarch, or a Bun slow path the new-in-183 code hits). clode is NOT a durable target
  (per user) — this is a *diagnostic anchor*, not an escape plan.

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
