# Claude Code hangs at 100% CPU on a single non-Latin1 character in any large multi-line string it line-splits (no-AVX2 hardware)

**Status:** root-caused to the instruction level. Reproducible **through 2.1.220**
(the latest release at time of writing). Not yet fixed upstream.
**Reporter context:** running Claude Code on a pre-AVX2 Mac (Ivy Bridge, OS X 10.9)
via an AVX2 trap-and-emulate shim (`libavxemu`). See "Scope" for why that matters —
and why the underlying defect is **not** specific to that platform.

---

## Summary

On a CPU without AVX2, Claude Code **≥ 2.1.183** wedges a core **indefinitely** (100%
CPU, unresponsive prompt) whenever it **line-splits a large multi-line string that
contains at least one character above U+00FF** (an em-dash, arrow, curly quote,
emoji — anything non-Latin1). 2.1.179 is unaffected.

The character is not corrupt. One `—` is enough. The same input runs in <100 ms on
AVX2 hardware. The cost is **O(lines × length)**, so it scales with the size of the
string being split — a few-KB hook payload takes tens of seconds under emulation; a
multi-hundred-KB conversation transcript never returns.

**Three confirmed trigger sites** (same instruction, same root cause):

1. A **`SessionStart` hook** whose `additionalContext` is multi-line + has one wide
   char (the minimal repro below).
2. An **on-demand plugin skill/agent file** loaded mid-session (e.g. a `SKILL.md`
   with an em-dash) — same effect the moment it's read.
3. **Resuming a conversation** (`claude -c` / `--resume`): the engine loads the prior
   transcript (`~/.claude/projects/<slug>/<uuid>.jsonl`) — routinely hundreds of KB,
   and full of the em-dashes/arrows/curly quotes Claude itself emits — and hangs
   while ingesting it. This is the most consequential vector: it needs no plugins and
   no hooks, and it fires on ordinary everyday use (any prior session containing one
   wide char in its history).

Vector #3 is significant because it cannot be worked around outside the engine: hooks
and skill files are static and can be pre-sanitized, but the conversation transcript
is content Claude generates itself.

## Affected / not affected

| | Engine | No-AVX2 result |
|---|---|---|
| Claude Code 2.1.179 | Bun 1.3.14 | fine (idles ~9 s) |
| Claude Code 2.1.183 / .185 / .198 / .201 | Bun "1.4.0" (fork build `324c5f012`) | **spins forever** |
| Claude Code **2.1.220** (latest) | Bun-fork "1.4.0" | **still spins** (wide payload → `TTIDLE=none` @ ~100% CPU over 90 s; ASCII twin idles in ~15 s) |
| stock Bun 1.3.14 / 1.4.0-canary, same emulator | — | fine (string battery clean) |

So the trigger is specific to the **embedded Bun-fork build** shipped in Claude Code
≥ 2.1.183, exercised on a non-AVX2 host — and it is **unchanged through the latest
release**. (Separately, ≥ 2.1.214 also newly imports `__ulock_wait`, a 10.12+ symbol;
that is a distinct load-time issue, not this spin.)

## Minimal reproduction (plugin-free)

Trusted project (hooks only run in trusted projects). User settings:

```json
{ "hooks": { "SessionStart": [ { "matcher": "startup|clear|compact",
  "hooks": [ { "type": "command", "command": "cat /path/to/payload.json" } ] } ] } }
```

`payload.json` — a SessionStart hook result whose `additionalContext` is ~3 KB, ~75
lines, containing exactly **one** char > U+00FF:

```json
{ "hookSpecificOutput": { "hookEventName": "SessionStart",
  "additionalContext": "line one\nline two\n...—...\nlast line" } }
```

Launch Claude Code in the trusted project on a no-AVX2 host → 100% CPU, never idles
(measured `TTIDLE=none, maxcpu=102%` over 45 s; a clean run idles in ~9 s). Replacing
the single `—` with `--` (all bytes ≤ U+00FF) → idles normally. Bisected to a
100% clean separation: pure-ASCII payload idles; +1 wide char pegs. Re-confirmed on
**2.1.220**: wide payload `TTIDLE=none` (90 s @ ~100% CPU), ASCII twin idles in ~15 s.

## Reproduction — conversation resume (no hooks, no plugins)

Even more directly: have any prior Claude Code session whose transcript contains at
least one non-Latin1 character (Claude's own replies routinely include em-dashes,
arrows and curly quotes, so this is essentially every real session), then:

```
claude -c        # or:  claude --resume
```

On a no-AVX2 host the process wedges at 100% CPU while loading the transcript and
never reaches the prompt. Observed with a 1.3 MB `~/.claude/projects/<slug>/<uuid>.jsonl`
containing raw-UTF-8 em-dashes on ~99 of its lines (killed after ~4.5 min at a steady
100% CPU). The larger the transcript, the worse it is (O(n·m) — see below): a modest
hook payload is tens of seconds, a real transcript is effectively forever.

## Root cause (instruction level)

The non-Latin1 character forces JavaScriptCore to store the hook string in its
**16-bit (UTF-16)** representation instead of the 8-bit (Latin1) one. The app then
**line-splits** that string — repeated `indexOf('\n')` / split — and **each search
re-materializes the whole rope**, so the total work is O(lines x length) full
16-bit rematerializations that use AVX2 vector code.

Evidence from an execution-stream sample of the wedged process (2.1.185, static
offsets = pc − `__TEXT` base):

- **Hot native routine: `fn44058` at `+0x256e290`** — a 16-bit character search.
  Sampled mid-scan at `+0x256e593` with registers:
  - `r14 = 0xa` — the search character is **newline**.
  - `r13 = 0xd90` (3472) — the string length.
  - `rax = 0xffffffff` — the "not found" sentinel.
  - `rdx`/`rsi` walk a UTF-16 buffer whose dumped contents **are the hook text**.
- Call chain: bytecode interpreter (`fn67339`, `+0x37cee8b`) → `fn44061` (the
  split/iterate driver) → `fn44058` (the 16-bit search).
- **The exact faulting instruction is `lzcnt` (`66 f3 0f bd cf`, `lzcnt cx,di`)
  at `+0x256e58e`**, inside `fn44058`'s SIMD search loop:
  ```
  +0x256e57d  vpcmpeqw xmm0, xmm0, [r12]   ; 128-bit AVX — compare 8 UTF-16 chars to the search char
  +0x256e583  vpmovmskb edi, xmm0          ; 128-bit AVX — matches -> bitmask
  +0x256e58a  test edi,edi / je            ; any match in this chunk?
  +0x256e58e  lzcnt cx, di                 ; <-- BMI1/ABM, ABSENT on Ivy Bridge -> traps & is emulated
  +0x256e593  movzx/shr/xor/lea            ; bit position -> char index
  ```
  The `vpcmpeqw`/`vpmovmskb` are VEX.128 (plain AVX) and run **natively** on this
  CPU. Only the `lzcnt` faults. Extracted live from the wedged process by reading
  the emulator thunk's resume pointer (`jmpq *0xbe(%rip)` -> resume `+0x256e593`,
  so the trampolined instruction is the 5 bytes ending there).
- So the emulated hot op is **one `lzcnt` per matching 8-char chunk**, and the
  ~69% spill is the emulator's full register save/restore around that single
  scalar instruction — repeated across the re-searched string without end.
- Inside the spin, ~69% of samples are register spill/restore around the emulated
  AVX2 op, ~11% the op itself. It is a **fixed, deterministic** re-scan (loop
  registers byte-identical across samples), not a size-dependent slowdown: a clean
  1800 s run never idles.

This is **not** JIT'd code — `JSC_useJIT=false` still spins — so the pathology is in
the compiled C++ string/rope layer, at fixed `__TEXT` offsets.

## Why it is fatal only on no-AVX2 — but latent everywhere

The routine is correct; on AVX2 silicon the vector rematerialization is fast and a
few-KB line-split finishes in <100 ms. Under trap-and-emulate the AVX2 ops cost ~100×
plus per-op register-spill overhead, so a per-line rematerialization that is invisible
natively becomes effectively unbounded. **But the O(n·m) rematerialization itself is a
CPU-independent defect** — the emulated Mac just hits the wall first.

It should be measurable on **supported hardware** too: because the cost is
O(lines × length) of the string being split, feeding an artificially large
`additionalContext` (or resuming a large transcript) with one wide char vs. its
all-ASCII twin should show a super-linear CPU-time delta that grows with size, even
where each individual op is fast. A profile of that run on any platform should land in
the same 16-bit character-search routine. (We can only measure the emulated extreme
here; a scaling run on native AVX2 hardware would quantify the latent cost directly.)

## Suggested fix (upstream)

Stop re-materializing the rope on every `indexOf`/split iteration when the string is
16-bit — i.e. **flatten the rope once and reuse it** across the whole line-split (or
split once into an array), rather than re-resolving on each iteration. Equivalently,
take the 8-bit fast path where the content is Latin1-representable. The line-split of a
string should be O(length), not O(lines × length), regardless of CPU.

This is fixable at **either** layer:
- **App level (Claude Code's own JS):** at the sites that ingest and line-split large
  strings — SessionStart `additionalContext`, transcript load on resume, context
  assembly — flatten the string once before iterating. Cheapest and fully within
  Anthropic's own code; no engine change.
- **Engine level (the Bun-fork JSC):** fix `indexOf`/split on a 16-bit rope so it
  resolves the rope once instead of re-materializing per call. Deeper, shared with
  upstream Bun/WebKit, but fixes the whole class.

## Local mitigations (in use — and their limit)

- **Transliterate** non-Latin1 chars down to ≤ U+00FF in any content a `SessionStart`
  hook emits, and in any plugin skill/agent file a session may load on demand.
  Idempotent; zero functionality loss. This covers vectors #1 and #2.
- A launcher that does the above automatically and refuses to start rather than hanging
  silently on a still-wide hook.
- **Vector #3 (conversation resume) has no external mitigation.** The transcript is
  content Claude generates; pre-folding it means rewriting the conversation record, and
  it does not help a long-running live session as its history grows. Only the upstream
  fix above closes this vector. (This is why the reporter, despite clearing the two
  load-time issues, cannot run current Claude Code for real work on this hardware.)

## Evidence / artifacts

- `docs/evidence/2026-07-02-recurrence/forensic-phaseA-hook-string.out` — the
  execution-stream sample (routine, registers, the captured UTF-16 buffer).
- `docs/evidence/2026-07-02-recurrence/payload_pretty_{wide,ascii}.json` — the
  poisoned vs clean payloads.
- `docs/evidence/2026-07-02-recurrence/hook-bisect-results.txt` — the 1-wide-char
  bisection.
- Disassembly: `fn44058` = `+0x256e290`; its length-gated 16-bit fast path calls
  `+0x2589c10`; rope resolve `+0x3192180`. (Offsets are for 2.1.185; re-derive per
  build.)
- `docs/evidence/2026-08-10-latest-upgrade/LOG.md` — reproduction on **2.1.220**
  (wide spins, ASCII idles) and the `claude -c` resume hang (transcript vector #3),
  with the exact harnesses.
- `scripts/spin_repro.sh` — one-command faithful, plugin-free reproduction
  (`spin_repro.sh <version> <wide|ascii>`): builds a throwaway HOME with a SessionStart
  hook that `cat`s the wide/ASCII payload and measures time-to-idle. Confirmed to
  reproduce on 2.1.185 and 2.1.220 and to idle on the ASCII twin.
