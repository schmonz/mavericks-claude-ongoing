# avxemu Startup-Spin Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make trusted-project startup of upstream Claude Code 2.1.183+ usable on the no-AVX2 Mac — from a multi-minute 100%-CPU spin down to a few seconds — by attacking the AVX2-emulation cost in `libavxemu`.

**Architecture:** The spin is *correct but catastrophically slow emulated AVX2*: each AVX2 instruction is trapped via SIGILL and emulated, costing ~60µs (dtrace: 52K `sigreturn`/3s ≈ 17K instr/s). Two attack tracks. **Track C (primary):** identify the one hot native Bun routine looping in AVX2, replace it with a bit-exact scalar/SSE C function interposed in the dylib (same DYLD-interpose + jmp-patch the emulator already uses). **Track D (fallback/durable):** a hot-loop JIT in the emulator that translates a hot run of AVX2 into a native SSE block executed without per-instruction traps. Phase 1 is a deterministic decision gate that routes to C or D.

**Tech Stack:** C, x86-64 assembly, macOS 10.9 (`dtrace`, `vmmap`, `otool`, `lldb`, `nm`), the existing avxemu differential-test harness (`build.sh`, runs ground-truth on a Haswell box), Python pty harnesses for repro.

---

## GUARDRAILS — read before doing anything (this is where prior sessions were burned)

**Read first, in full:** `docs/STARTUP-HANG-OPTIONS.md` (the fresh-agent brief) and
`docs/RULED-OUT.md` (the eliminated-list). This plan assumes you have.

**SETTLED — do NOT re-derive (re-proving these IS the failure mode):**
- It's emulated AVX2, finite-but-slow, *correct* emulation (Haswell oracle: 0 failures).
  The `sigreturn` storm confirms this; it is not news.
- Trigger is the **trust gate**, content-independent — reproduces in an EMPTY trusted
  dir. NOT transcripts/project-size (that theory is dead; the `aHf`/`iHf` scanner is
  byte-identical 179↔183).
- 179 / untrusted / clode(Node) idle; trusted 185/183 spins. Render core unchanged.

**Do NOT CHASE (all tried, all noise or dead):** plugins/skills/hooks as "the input"
(bimodal sync noise — never conclude from one idle draw; this trap was hit twice),
terminal capability queries (DA/XTVERSION/OSC11 — refuted), tmux, the computer-use
MCP, the `libSystemWrapper` write shim, the headless `-p` profiler (different
pre-existing "grove" path), cpuid→scalar (hot AVX2 is unconditional Bun code, not
cpuid-gated; global no-AVX2 hangs at boot).

**WALLS — do not re-attempt without a genuinely new idea:** Bun CDP inspector (can't
extract while main thread wedged in native), `sample`/dtrace `ustack()` (JIT frames
anonymous — no JS names), `--debug` log (silent during the spin), clode/Node (doesn't
reproduce — no emulation).

**Discipline:** consult the two docs before each experiment; repeat measurements ≥3×
(the system is bimodal/noisy); the goal is the FIX, not re-characterizing the spin.

---

## Repro & measurement primitives (used by many tasks)

- **Trust the test dir** (always back up + restore `~/.claude.json`):
  ```bash
  cp ~/.claude.json /tmp/cj.bak
  python3 - <<'PY'
  import json,os
  p=os.path.expanduser('~/.claude.json'); d=json.load(open(p))
  k="/Users/schmonz/Documents/code/trees/trusttest"
  d.setdefault("projects",{})[k]={"hasTrustDialogAccepted":True}
  json.dump(d,open(p,"w"))
  PY
  # ... run test in that dir ...
  cp /tmp/cj.bak ~/.claude.json   # ALWAYS restore
  ```
- **Harnesses (already on disk):** `scripts/pyte_watch.py <secs>` (CPU% per 3s; reliable),
  `scripts/pyte_type.py` (writes child pid to `/tmp/spin.pid`, holds it alive for probing).
  Launchers `scripts/claude_179`, `scripts/claude_185`. `LAUNCHER=...` env selects version.
- **The spin is finite with variable duration** — usually 90s+, sometimes <12s. Poll
  CPU and confirm `>70%` before measuring.

---

## Phase 1 — Identify the hot routine (deterministic; the C-vs-D decision gate)

> **Already provided:** `scripts/catch-spin.sh` and `scripts/hot-offset.sh` ship in
> this repo (the code shown in Tasks 1-2 below matches them). You can skip writing/
> committing them and go straight to *running* them; Tasks 1-2 document what they do
> and the verification bar (a STABLE offset across ≥3 caught spins before the gate).

### Task 1: Robust spin-capture harness

**Files:**
- Create: `scripts/catch-spin.sh`

- [ ] **Step 1: Write the capture script**

```bash
#!/bin/sh
# catch-spin.sh — launch trusted 2.1.185, wait until it is confirmed spinning
# (CPU>70%), then print the live pid and the binary __TEXT load base. Leaves the
# process running (kill it yourself). Restores ~/.claude.json on the way in.
set -u
D=/Users/schmonz/Documents/code/trees/trusttest
mkdir -p "$D"; [ -f "$D/README.md" ] || echo hello > "$D/README.md"
cp ~/.claude.json /tmp/cj.bak
python3 - "$D" <<'PY'
import json,os,sys
p=os.path.expanduser('~/.claude.json'); d=json.load(open(p))
d.setdefault("projects",{})[sys.argv[1]]={"hasTrustDialogAccepted":True}
json.dump(d,open(p,"w"))
PY
( cd "$D" && rm -f /tmp/spin.pid && LAUNCHER=scripts/claude_185 python3 scripts/pyte_type.py >/tmp/ptype.out 2>&1 & )
PID=""
i=0
while [ $i -lt 25 ]; do
  sleep 2; i=$((i+1))
  PID=$(cat /tmp/spin.pid 2>/dev/null) || PID=""
  [ -n "$PID" ] || continue
  CPU=$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ')
  case "$CPU" in ''|*[!0-9.]*) continue;; esac
  if [ "${CPU%.*}" -ge 70 ]; then break; fi
done
cp /tmp/cj.bak ~/.claude.json
BASE=$(vmmap "$PID" 2>/dev/null | awk '/__TEXT/ && /2\.1\.185/{print $2; exit}')
echo "PID=$PID CPU=$CPU TEXT_BASE=$BASE"
```

- [ ] **Step 2: Make it executable and run it 3×**

Run: `chmod +x scripts/catch-spin.sh; for n in 1 2 3; do sh scripts/catch-spin.sh; pkill -9 -f versions/2.1.185; sleep 2; done`
Expected: 3 lines like `PID=NNNNN CPU=9x.x TEXT_BASE=0x...`. If any line shows `CPU` < 70 or empty `TEXT_BASE`, the spin wasn't caught — increase the loop bound / retry. You need a reliably-spinning pid before Task 2.

- [ ] **Step 3: Commit**

```bash
git add scripts/catch-spin.sh
git commit -m "tools: reliable avxemu spin-capture harness"
```

### Task 2: Capture the hot PC and compute the binary offset

**Files:**
- Create: `scripts/hot-offset.sh`

- [ ] **Step 1: Write the hot-PC sampler**

```bash
#!/bin/sh
# hot-offset.sh PID BASE — dtrace-sample the user PC of a spinning pid, print the
# top binary offsets (hotPC - BASE). sudo works non-interactively on this host.
set -u
PID="$1"; BASE="$2"
sudo -n dtrace -q -n "profile-1999 /pid==$PID/ { @[arg1]=count(); } tick-3s { exit(0); }" 2>/dev/null \
| awk 'NF==2{print}' | sort -k2 -n | tail -10 \
| while read PC CNT; do
    OFF=$(python3 -c "print(hex($PC-$BASE))" 2>/dev/null)
    echo "off=$OFF count=$CNT pc=$(printf '0x%x' "$PC")"
  done
```

- [ ] **Step 2: Run capture+sample together, 3× (offsets must be stable)**

Run:
```bash
chmod +x scripts/hot-offset.sh
for n in 1 2 3; do
  eval "$(sh scripts/catch-spin.sh | tail -1)"   # sets PID, CPU, TEXT_BASE
  sh scripts/hot-offset.sh "$PID" "$TEXT_BASE"
  pkill -9 -f versions/2.1.185; sleep 2
done
```
Expected: a dominant `off=0x...` that is **the same across all 3 runs** (ASLR changes BASE and PC, but `off` is stable). Record the top 1-3 stable offsets.

- [ ] **Step 3: DECISION GATE — is the hot offset in the binary's `__TEXT` (native) or in JIT?**

Run: `otool -tV ~/.local/share/claude/versions/2.1.185 2>/dev/null | head -1; size ~/.local/share/claude/versions/2.1.185 2>/dev/null` — confirm `__TEXT` size. If the dominant `off` is **inside `__TEXT`** (i.e. catch-spin reported a TEXT mapping spanning it; a ~55MB `__TEXT` from earlier vmmap), it is a **stable native Bun routine → proceed Track C (Task 3)**. If the hot PC is **outside `__TEXT`** (JIT region; address far above the mapped image), Track C's interpose won't bind cleanly → **switch to Track D** (see "Track D" section) and stop here.

- [ ] **Step 4: Commit**

```bash
git add scripts/hot-offset.sh
git commit -m "tools: dtrace hot-PC -> binary offset for avxemu spin"
```

### Task 3: Disassemble and classify the hot routine

**Files:**
- Create: `docs/hot-routine.md` (findings, committed for the next engineer)

- [ ] **Step 1: Disassemble the routine around the hot offset**

Run (replace `OFF` with the stable offset; `--start-address`/`--stop-address` are file offsets into `__TEXT`):
```bash
otool -tV ~/.local/share/claude/versions/2.1.185 2>/dev/null \
  | awk -v o="OFF" 'index($1,substr(o,3)){p=1} p{print} p&&++n>400{exit}' > /tmp/hot.asm
head -120 /tmp/hot.asm
```
(If `otool` addressing is awkward on this stripped binary, use lldb:
`lldb -o "target create ~/.local/share/claude/versions/2.1.185" -o "disassemble --start-address <BASE+OFF> --count 200" -o quit` against a live caught pid using its real BASE.)

- [ ] **Step 2: Cross-check with the emulator's own op histogram**

Run a caught spin with `AVXEMU_OPSTATS=1 AVXEMU_FULLTHUNK=1` set in the launcher env, capture the histogram (see `avxemu/src/handler.c` for how it dumps). Expected: a small set of dominant ops (prior runs saw `vpbroadcastd`, `vpmovzxbw`, `shlx/lzcnt/bzhi/tzcnt/andn`, `vpcmpgtb`, ... — transcoding/string-width shaped).

- [ ] **Step 3: Write up the routine in `docs/hot-routine.md`**

Document: the stable offset, the disassembled loop, the dominant AVX2 ops, the inferred purpose (e.g. simdutf UTF-8↔UTF-16 transcode / simdjson stage1 / `Buffer.indexOf` memchr / string-width), and the **callee ABI** (which registers carry the in/out pointers + length; calling convention). This is the contract Track C must reproduce bit-exactly.

- [ ] **Step 4: Commit**

```bash
git add docs/hot-routine.md
git commit -m "docs: identify + classify the hot avxemu startup routine"
```

---

## Phase 2 — Track C: bit-exact scalar/SSE replacement (TDD via the oracle)

> Only enter Phase 2 if Task 2's gate routed to Track C. The avxemu repo already has a
> differential-test discipline (`build.sh` runs ground truth on a Haswell box). Reuse it.

### Task 4: Differential test for the replacement (write the failing test first)

**Files:**
- Create: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/test/shim_<routine>_test.c`
- Test runner: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/build.sh` (existing; extend)

- [ ] **Step 1: Write the differential test**

Implement a test that generates representative inputs for the routine (per its ABI
from `hot-routine.md`) — including the edge cases the dominant ops imply (multi-byte
UTF-8 boundaries, lengths around 16/32-byte SIMD strides, empty, ASCII-only, etc.) —
and compares `shim_<routine>(input)` against the known-correct reference (the existing
oracle / a straightforward scalar spec). Assert byte-exact equality for every case.
(Write the actual cases in code — no "add edge cases" placeholders.)

- [ ] **Step 2: Run it and verify it FAILS (no shim yet)**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh <test-target>`
Expected: FAIL — `shim_<routine>` undefined / not linked.

- [ ] **Step 3: Commit the failing test**

```bash
git add /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/test/shim_<routine>_test.c
git commit -m "test: differential oracle for <routine> shim (failing)"
```

### Task 5: Implement the scalar/SSE4 replacement

**Files:**
- Create: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/src/shim_<routine>.c`

- [ ] **Step 1: Implement `shim_<routine>` to the documented ABI**

Write a correct scalar (or SSE4-only — this box has SSE4.2) implementation matching the
routine's contract. Correctness first; it only has to beat ~17K-instr/s emulation, so
even scalar wins enormously.

- [ ] **Step 2: Run the differential test — verify PASS**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh <test-target>`
Expected: PASS — byte-exact on all cases.

- [ ] **Step 3: Run the FULL existing differential suite (no regressions)**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh`  (on the Haswell box per the repo's normal flow)
Expected: 0 failures, as before.

- [ ] **Step 4: Commit**

```bash
git add /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/src/shim_<routine>.c
git commit -m "feat: bit-exact scalar/SSE shim for <routine>"
```

---

## Phase 3 — Track C: interpose + end-to-end verification

### Task 6: Interpose the shim over the native routine

**Files:**
- Modify: `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/src/handler.c` (add the interpose, gated
  by an env knob `AVXEMU_SHIM_<ROUTINE>=1`, default on; follow the existing
  cpuid/lzcnt jmp-patch pattern)

- [ ] **Step 1: Add the 5-byte jmp-patch / DYLD interpose at the routine's offset**

Reuse the emulator's existing patch machinery (the same approach used for cpuid/lzcnt).
Resolve the routine by its stable image offset at load time; install a `jmp shim_<routine>`.
Guard with `AVXEMU_SHIM_<ROUTINE>` so it can be A/B-toggled.

- [ ] **Step 2: Rebuild the dylib**

Run: `cd /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu && sh build.sh` (produces the dev dylib).
Install/point the launcher at it (see brief's setup section).
Expected: builds clean; differential suite still 0 failures.

- [ ] **Step 3: A/B the startup spin (the real success metric), 3× each**

Run (shim ON vs OFF via the env knob), in the trusted empty dir, via the pyte harness:
```bash
# ON:
for n in 1 2 3; do LAUNCHER=scripts/claude_185 python3 scripts/pyte_watch.py 30 | awk '/^ *[0-9]+ /{print $2}'; done
# OFF (AVXEMU_SHIM_<ROUTINE>=0): same
```
Expected: with the shim ON, CPU decays to idle within a few seconds (like 0-skills/179
do); with it OFF, it pegs 100%. Confirm the TUI is responsive (type into `pyte_type.py`
and see prompt echo promptly).

- [ ] **Step 4: If still slow — iterate, don't thrash**

If ON still pegs: the hot loop has more than one routine. Re-run Task 2 (`hot-offset.sh`)
WITH the first shim active to find the *next* dominant offset, and repeat Phase 2/3 for
it. Cap at the top ~3 routines; if it's death-by-a-thousand-ops, that's the signal to
switch to Track D.

- [ ] **Step 5: Commit**

```bash
git add /Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/src/handler.c
git commit -m "feat: interpose <routine> shim; trusted startup spin -> seconds"
```

### Task 7: Verify on a real project + document the win

**Files:**
- Modify: `docs/RULED-OUT.md`, `docs/STARTUP-HANG-OPTIONS.md` (record the outcome)

- [ ] **Step 1: Launch a real, trusted project (e.g. the clode repo) with the shim and time-to-usable**

Run it through `pyte_watch.py 60` (or directly) and confirm startup reaches an idle,
responsive TUI in a few seconds, with the differential suite still green.

- [ ] **Step 2: Update the docs with the result (offset, routine, before/after CPU)**

- [ ] **Step 3: Commit**

```bash
git add docs/RULED-OUT.md docs/STARTUP-HANG-OPTIONS.md
git commit -m "docs: avxemu startup spin fixed via <routine> shim"
```

---

## Track D — Hot-loop JIT in the emulator (fallback if Phase 1 gate → JIT, or Task 6.4 caps out)

This is a larger, open-ended subsystem and should be its OWN plan (brainstorm + spec it
separately). Sketch only:

- The cost is the per-instruction SIGILL trap (~60µs), not the emulation math. Detect a
  hot *run* of AVX2 (e.g. a basic block re-entered N times) in `tramp.c`, and translate
  it ONCE into a native SSE4 block executed in a loop with no per-instruction trap.
- Starting point: the trampoline machinery in `/Users/schmonz/Documents/code/trees/Mavericks-Porting-Resources/avxemu/src/tramp.c`
  (there is an uncommitted `AVXEMU_FULLTHUNK` toggle to build on).
- Verify with the SAME differential oracle (`build.sh`) — bit-exactness is non-negotiable
  — and the same pyte A/B startup metric.
- Payoff: general (helps all emulated code), durable; but materially more work than C.

**If you reach here from the gate:** stop and write a dedicated Track-D plan via
`superpowers:writing-plans` rather than improvising it inside this one.

---

## Self-review notes (for the executor)

- The one genuine unknown is Task 2's gate (native vs JIT hot PC). Everything downstream
  of "native" is standard avxemu engineering with an existing oracle. Don't proceed past
  the gate on a guess — get a *stable* offset across ≥3 caught spins first.
- Replace every `<routine>` / `OFF` placeholder with the concrete value from Phase 1
  before writing code. Those are intentional fill-ins from the investigation, not vague
  TODOs.
- Bit-exactness via `build.sh` is the gate on every shim change; the pyte CPU A/B is the
  gate on "did it actually fix startup."
