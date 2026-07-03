# RETROSPECTIVE — how we could have found the no-AVX2 spin in a day

The bug: Claude Code ≥2.1.183 pegs a core indefinitely at startup on no-AVX2
Macs when any SessionStart hook emits a character > U+00FF (the superpowers
plugin's `using-superpowers/SKILL.md`, via its em-dashes). It flips a JSC string
to 16-bit, and the embedded Bun-fork engine's ingestion of that string never
terminates under AVX2 emulation. Fix: transliterate ~6 punctuation chars.

It took ~two weeks and a long chain of deep mechanism work. It was findable in a
day. This is the honest account of which signals we had and underweighted, which
required work to become available, and the durable rules that follow.

Host shorthand: **oracle-air** = the AVX2 Haswell box used as the correctness
oracle. **target** = the no-AVX2 Mavericks (10.9) machine that spins.

---

## The signal we held for weeks and filed under "lab hygiene": trust

Untrusted projects never spun; trusted ones did. We knew this early — and wrote
it into the docs as a *methodology hazard* ("verify trust before every run or
you'll declare a false fix"), i.e. as measurement noise to defend against, not as
evidence pointing at the cause. But trust gates a small, enumerable set of
things: hooks, project settings, plugin engagement, MCP servers. "What does trust
turn ON? Ablate them one at a time" was a one-day experiment available from week
one. It is the single fastest path to the answer, and it is exactly the
experiment (plugin on/off) that eventually cracked it.

**Rule:** a clean boolean that correlates with a bug is *evidence*, not an
inconvenience to control for. When something reliably toggles the symptom, chase
the toggle before you profile the mechanism.

## The deeper error: we profiled code when we should have bisected environment

The failure was deterministic and configuration-gated. For that class,
config-space bisection (turn things off until the symptom stops) is cheap and
needs zero understanding of the mechanism. We did *binary* bisection early
(179 vs 183 — good; it found the Bun engine boundary) but never *config*
bisection until the end. Instead we went deep on mechanism — op histograms,
spill-cost models, trampoline tiers — all answering "HOW is it slow?" when the
question that cracked it was "WHEN is it slow?"

**Rule:** deterministic + config-gated ⇒ environment bisection BEFORE mechanism
analysis. "When does it happen?" outranks "how does it work?"

## Why we never stumbled into it: our repros were built cloned-down, not empty-up

To keep the bug alive, our throwaway repro HOMEs were built by copying the real
environment IN. Start-full-and-preserve guarantees you never observe the OFF
state — and the OFF state (bug disappears when X is removed) *is* the signal. An
empty HOME with things added back would have "lost" the bug immediately, and
losing the bug is the finding.

**Rule:** build minimal repros by construction (empty, add until it breaks), not
by cloning the world and subtracting. The thing whose removal kills the bug is
the answer.

## The arithmetic we did, believed, and then disobeyed

By 2026-06-30 the docs already said it: oracle-air does this startup in ~1.5
CPU-seconds; the target burns 600+ and never finishes. That is not "same work,
~100× slower ops" — emulation tax alone can't span that. It is *hundreds of times
more work*: a runaway path native machines never enter. We wrote that sentence and
then spent two more days building per-op speedups, because the avxemu workstream
had momentum, was buildable, and every subtask was individually satisfying.

**Rule:** when a back-of-envelope says "more work, not slower work," freeze the
op-optimization workstream that hour. Momentum and buildability are not evidence.

## The clue in the op histogram: "which bytes," not "which function"

Also from 2026-06-30: the hot ops were ~94% `vpbroadcastw` + `lzcnt` — rope /
UTF-16 string machinery. JS engines keep strings 8-bit unless something forces
them wide. "Why is a REPL doing massive UTF-16 work at startup? What non-Latin1
data are we feeding it?" was askable then. We kept asking "which function?" for
days; the winning question was "which bytes?" — and it was answered the moment we
dumped the string data the loop was chewing (the superpowers hook JSON) out of
live registers.

**Rule:** for a runaway loop, profile the DATA, not just the code. The contents of
the hot buffer often name the culprit faster than any call stack.

## The bimodality we averaged over instead of interrogating

The burst-vs-sustained "noise" that forced all our ≥3× repetition discipline: a
deterministic system that is bimodal has a hidden boolean input. Hunting that
boolean directly ("what differs between a burst run and a sustained run?") is
high-yield. We built statistical armor against the variance instead of asking what
the variance was telling us — which was, very likely, "did the poisoned ingestion
path engage this run."

**Rule:** treat bimodality/variance as an unread signal (a hidden input), not just
an obstacle to average away.

---

## Signals that genuinely required work to become available

Not everything was there to be seen on day one. Several load-bearing observations
had to be built:

- **The fault-storm fix was a prerequisite for legibility.** Before it, profiles
  were sigtramp noise; the steady state only became readable once the SIGILL storm
  died. (Ironically, fixing it also blinded FAULTSNAP — all fault samples then land
  in the first ~2s — which forced building the lldb execution-stream sampler, the
  tool that finally read the hook JSON out of registers.)
- **Timestamps on samples.** The pre-timestamp "recurrence" reading over-claimed
  coverage of the sustained phase; adding seq+time exposed that the samples were
  all from the startup burst.
- **Corrected attribution.** `<unknown binary>` frames were our own RWX thunk
  pool, not app JIT; the "avxemu is 0.007%" reading was a misattribution. Resolving
  anonymous frames (disasm / check the indirect-call target against the dylib
  range) was required before any app-vs-emulation split could be trusted.
- **The provenance check** ("Bun v1.4.0" is not a public release; it's a fork of
  unreleased main) took five minutes and reframed the entire ownership question —
  but note this one WAS available from the day we extracted the version strings. We
  simply didn't think to ask "is this even a real release?" for two weeks.

**Rule:** distrust any instrument without timestamps, any profile with unresolved
anonymous regions, and any offset not verified against a known landmark. And run
the cheap provenance check on every black-box component early.

## The "fails environmentally, ignore" trap (a miniature of the whole thing)

The oracle-air test failures (reloctest 201×, minspilltest segfault) were labeled
"environmental (RWX/dyld blocked), ignore." That was an unexplained signal filed
as noise — the same mistake as "trust is just hygiene." Printing the decline
*reason* took two minutes and turned "202 mysterious failures" into "reason 7,
rel32 range, 7.6GB site↔pool gap" — instantly a real, fixable C bug.

**Rule:** "fails environmentally" earns no more trust than any other unexplained
signal. Make the tool say WHY before you agree to ignore it.

---

## The compressed checklist

For the next hard, environment-specific bug in this codebase:

1. Deterministic + config-gated? → **environment/config bisection before
   mechanism.** "When?" before "how?"
2. Build the repro **empty-up**; the config whose removal kills the bug is the
   answer.
3. A boolean that toggles the symptom (trust, a flag, a plugin) is **evidence** —
   chase it now.
4. Back-of-envelope says "more work, not slower work"? **Freeze op-optimization.**
5. Runaway loop? **Profile the data** (dump the hot buffer's bytes), not only the
   stack.
6. **Provenance-check** every black-box component (versions, is-it-even-released) —
   five minutes, can reframe ownership.
7. Distrust untimestamped instruments, unresolved anonymous frames, unverified
   offsets, and any signal you're tempted to call "environmental."
8. Treat variance/bimodality as a **hidden input** to find, not noise to average.
