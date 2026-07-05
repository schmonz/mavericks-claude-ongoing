# Claude Code hangs at 100% CPU on a single non-Latin1 character in a SessionStart hook (no-AVX2 hardware)

**Status:** root-caused to the instruction level. Reproducible. Not yet fixed upstream.
**Reporter context:** running Claude Code on a pre-AVX2 Mac (Ivy Bridge, OS X 10.9)
via an AVX2 trap-and-emulate shim (`libavxemu`). See "Scope" for why that matters.

---

## Summary

On a CPU without AVX2, Claude Code **≥ 2.1.183** wedges a core **indefinitely** (100%
CPU, unresponsive prompt) at session start whenever a `SessionStart` hook emits an
`additionalContext` string that is **multi-line** and contains **at least one
character above U+00FF** (an em-dash, arrow, curly quote, emoji — anything
non-Latin1). 2.1.179 is unaffected.

The character is not corrupt and the payload is not large. One `—` in a few KB of
otherwise-ASCII text is enough. The same input runs in <100 ms on AVX2 hardware.

## Affected / not affected

| | Engine | No-AVX2 result |
|---|---|---|
| Claude Code 2.1.179 | Bun 1.3.14 | fine (idles ~9 s) |
| Claude Code 2.1.183 / .185 / .198 / .201 | Bun "1.4.0" (fork build `324c5f012`) | **spins forever** |
| stock Bun 1.3.14 / 1.4.0-canary, same emulator | — | fine (string battery clean) |

So the trigger is specific to the **embedded Bun-fork build** shipped in Claude Code
≥ 2.1.183, exercised on a non-AVX2 host.

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
100% clean separation: pure-ASCII payload idles; +1 wide char pegs.

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

## Why only on no-AVX2 hardware

The routine is correct; on AVX2 silicon the vector rematerialization is fast and the
line-split finishes in <100 ms. Under trap-and-emulate the AVX2 ops cost ~100x plus
per-op register-spill overhead, so a per-line rematerialization that is invisible
natively becomes effectively unbounded. The bug is therefore **latent everywhere**
(an O(n·m) rematerialization on 16-bit strings) and only *fatal* where AVX2 is
emulated — but the O(n·m) rematerialization itself is an engine issue independent of
the CPU.

## Suggested fix (upstream)

Stop re-materializing the rope on every `indexOf`/split iteration when the string is
16-bit — i.e. flatten once and reuse (or take the 8-bit fast path where the content
is Latin1-representable). The line-split of a few-KB string should not perform
thousands of full 16-bit rematerializations regardless of CPU.

## Local mitigations (in use)

- **Transliterate** the ~handful of non-Latin1 punctuation/box/emoji chars in any
  content a `SessionStart` hook emits (and, for plugin ecosystems, any skill file a
  session may load on demand) down to ≤ U+00FF. Idempotent; zero functionality loss.
- A launcher that does the above automatically and refuses to start if an enabled
  hook still emits a wide char, rather than hanging silently.

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
