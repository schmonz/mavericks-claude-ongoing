# ModernMavericks/avxemu Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lift `avxemu/` out of `Mavericks-Porting-Resources` into a standalone
`ModernMavericks/avxemu` repo with its commit history, authorship and dates
intact, and nothing about the code changed.

**Architecture:** `git filter-branch --subdirectory-filter` on a throwaway clone,
verified against the source tree byte for byte, then a small amount of
standalone-repo hygiene (honest `build.sh` defaults, a README that states the
AVX2 oracle constraint, a LICENSE), then the repo creation and push.

**Tech Stack:** git 2.54.0, BSD userland on macOS 10.9, clang (Apple LLVM 6.0),
`gh` CLI authenticated over HTTPS.

**Spec:** `docs/superpowers/specs/2026-09-08-modernmavericks-claude-decomposition-design.md`

## Global Constraints

- **The extraction changes no code.** Any behaviour change is a separate commit
  after the move, never folded into it.
- **The AVX2 oracle machine's hostname must never appear in the repo**, in any
  file, commit message, or issue. Refer to it as "an AVX2 machine".
- **Licence:** public domain / CC0 / WTFPL, per Wowfunhappy in
  `Wowfunhappy/Mavericks-Porting-Resources` issue #4 (closed 2026-09-08). avxemu
  carries no third-party code.
- **This box has no `git subtree` and no `git-filter-repo`.** Use `filter-branch`.
  BSD `xargs` has no `-r`, BSD `grep` has no `-z`: GNU index-filter recipes fail
  silently and produce an unfiltered clone that looks like success.
- **Do not modify `Mavericks-Porting-Resources` in this plan.** Removing the
  original `avxemu/` is a later, coordinated PR against Wowfunhappy's repo.
- **Pushing and repo creation are outward-facing.** Task 6 must be explicitly
  approved at execution time, not assumed from this plan's existence.

---

## File Structure

Created in the new repo, on top of the extracted tree:

| file | responsibility |
|---|---|
| `README.md` | *modified* — standalone context: what it is, how to build, the AVX2 oracle constraint, provenance |
| `LICENSE` | *created* — CC0/WTFPL dedication naming both authors |
| `build.sh` | *modified* — `PUBLIC` and `CLAUDE_BIN` defaults that are honest off Wowfunhappy's machine |

Unchanged and carried verbatim: `src/` (17 files), `test/`, and the rest of
`build.sh`.

---

### Task 1: Extract with history, and prove the result is faithful

**Files:**
- Create: `$WORK/avxemu` (a new local git repo; `$WORK` is any scratch dir)
- Read: `~/Documents/code/trees/Mavericks-Porting-Resources`

**Interfaces:**
- Produces: `$WORK/avxemu`, a git repo whose `master` has 13 commits and whose
  worktree is byte-identical to `Mavericks-Porting-Resources/avxemu/`. Every
  later task operates inside it.

- [ ] **Step 1: Clone the source to a throwaway (never filter in place)**

```bash
SRC=$HOME/Documents/code/trees/Mavericks-Porting-Resources
WORK=$(mktemp -d /tmp/avxemu-extract.XXXXXX)
git clone --no-local "$SRC" "$WORK/avxemu"
git -C "$WORK/avxemu" checkout master
```

`--no-local` forces a real object copy rather than hardlinks, so a mistake here
can never damage the source repo's object store.

- [ ] **Step 2: Record what the result must match**

```bash
git -C "$SRC" log --oneline master -- avxemu | wc -l          # expect 13
find "$SRC/avxemu" -type f | wc -l                            # expect 55
```

Write both numbers down. They are the assertions for Step 5.

- [ ] **Step 3: Run the extraction**

```bash
FILTER_BRANCH_SQUELCH_WARNING=1 \
  git -C "$WORK/avxemu" filter-branch -f --subdirectory-filter avxemu master
```

Expected: a `Rewrite …(13/13)` progress line, then
`Ref 'refs/heads/master' was rewritten`.

- [ ] **Step 4: Drop the rewrite leftovers**

```bash
git -C "$WORK/avxemu" remote remove origin
rm -rf "$WORK/avxemu/.git/refs/original"
git -C "$WORK/avxemu" reflog expire --expire=now --all
git -C "$WORK/avxemu" gc --prune=now --quiet
```

Without this the pre-rewrite objects stay reachable and the pushed repo carries
the whole of Mavericks-Porting-Resources in its object store.

- [ ] **Step 5: Verify fidelity — this is the test**

```bash
SRC=$HOME/Documents/code/trees/Mavericks-Porting-Resources
echo "commits: $(git -C "$WORK/avxemu" log --oneline | wc -l)   want 13"
echo "root:    $(git -C "$WORK/avxemu" ls-tree --name-only HEAD | tr '\n' ' ')"
diff -r "$SRC/avxemu" "$WORK/avxemu" -x .git && echo "TREE IDENTICAL"
git -C "$WORK/avxemu" log --format='%an' | sort -u
```

Expected: 13 commits; root is exactly `README.md build.sh src test`;
`TREE IDENTICAL`; authors are exactly `Amitai Schleier` and `Wowfunhappy`.

**If `diff -r` reports differences, stop.** The extraction is wrong; do not
continue and do not push.

- [ ] **Step 6: Verify it still builds standalone**

```bash
cd "$WORK/avxemu" && sh build.sh 2>&1 | head -8
```

Expected: step `[1]` compiles, step `[2]` prints `clean` (no VEX leak), then
step `[3]` or `[4]` dies with `Illegal instruction`. **That failure is correct
on a non-AVX2 machine** and is exactly the constraint Task 3 documents. Reaching
step 3 at all proves the tree is self-contained.

- [ ] **Step 7: Commit nothing**

There is nothing to commit — the history *is* the deliverable. Confirm the tree
is clean:

```bash
git -C "$WORK/avxemu" status --short    # expect no output
```

---

### Task 2: Give `build.sh` defaults that are honest off Wowfunhappy's machine

**Files:**
- Modify: `$WORK/avxemu/build.sh:15` and `:108`

**Interfaces:**
- Consumes: `$WORK/avxemu` from Task 1.
- Produces: a `build.sh` whose `install` target refuses rather than writing to a
  path that does not exist, and whose optional binary fixture is version-agnostic.

- [ ] **Step 1: See the current defaults fail**

```bash
grep -n 'PUBLIC=\|BINARY=' "$WORK/avxemu/build.sh"
```

Expected, and both wrong outside one machine:

```
15:PUBLIC="${PUBLIC:-/Users/Jonathan/Developer/Mavericks Forever/public/claude}"
108:BINARY="${CLAUDE_BIN:-$HOME/.local/share/claude/versions/2.1.166}"
```

- [ ] **Step 2: Make `install` refuse rather than guess**

Replace line 15 with:

```sh
# No default: `install` copies the built dylib somewhere it will be published
# from, and there is no sane guess for that off the machine that publishes it.
PUBLIC="${PUBLIC:-}"
```

Then, in the `install` branch near line 177, replace the copy with:

```sh
    [ -n "$PUBLIC" ] || { echo "set PUBLIC=<dir> to install"; exit 1; }
    cp "$OUT/libavxemu.dylib" "$PUBLIC/libavxemu.dylib"
```

- [ ] **Step 3: Make the optional fixture version-agnostic**

Replace line 108 with:

```sh
# Optional: step 7 fuzzes the decoder against a real AVX2-targeted binary. Any
# will do; the newest installed Claude Code is a convenient one. Steps 1-6 do
# not need it.
BINARY="${CLAUDE_BIN:-$(ls -1d "$HOME"/.local/share/claude/versions/* 2>/dev/null | tail -1)}"
```

- [ ] **Step 4: Verify the build still reaches the same point**

```bash
cd "$WORK/avxemu" && sh build.sh 2>&1 | head -6
PUBLIC= sh build.sh install 2>&1 | tail -2
```

Expected: same `[1]`/`[2] clean` as before; the `install` run ends with
`set PUBLIC=<dir> to install` rather than a copy into a nonexistent directory.

- [ ] **Step 5: Commit**

```bash
cd "$WORK/avxemu"
git add build.sh
git commit -m "build: defaults that work off the machine that publishes releases

PUBLIC pointed at one person's Developer directory and CLAUDE_BIN at a
Claude Code version from June. Neither is wrong there and both are wrong
everywhere else, which is the kind of thing a repo only notices once it
has more than one user.

install now refuses without PUBLIC instead of copying into a directory
that does not exist, and the optional step-7 fixture picks the newest
installed version instead of naming one."
```

---

### Task 3: A README that stands alone, and states the oracle constraint

**Files:**
- Modify: `$WORK/avxemu/README.md`

**Interfaces:**
- Consumes: `$WORK/avxemu` from Task 2.
- Produces: a README that answers "what is this, how do I build it, why does the
  build fail here" without reference to Mavericks-Porting-Resources.

- [ ] **Step 1: Read what is there**

```bash
cat "$WORK/avxemu/README.md"
```

- [ ] **Step 2: Add the standalone framing at the top**

Prepend, keeping everything already there below it:

```markdown
# avxemu

Runs AVX2/FMA/BMI binaries on CPUs that lack those instructions, by trapping
SIGILL and emulating the faulting instruction — and, where it can prove doing so
is safe, by patching the site to jump to an emitted SSE lowering instead.

Built for Mac OS X 10.9 on pre-2013 hardware, where recent builds of Node, Bun
and Claude Code are compiled for Haswell and fault on the first vector
instruction.

## Building

    ./build.sh            build, run every test, produce libavxemu.dylib
    PUBLIC=<dir> ./build.sh install    also copy the dylib to <dir>

## The build needs two machines

`build.sh` cannot run end to end on one host, and this is worth knowing before
you conclude something is broken:

- **Steps 3, 4 and 6b are differential oracles.** They compare the emulator
  against real AVX2/FMA/BMI hardware, so they need a machine that *has* those
  instructions — which by definition is not the machine avxemu exists for. On
  the target platform they fail with `Illegal instruction`. That is expected.
- **Steps 8, 8i and 8a exercise the 10.9 dynamic loader** — `DYLD_INSERT_LIBRARIES`
  interposition, and the rebind that a linked (rather than inserted) build needs.
  Modern macOS strips `DYLD_*` for system binaries, so these cannot run there.

Neither host runs all of it. That gap is not academic: it is how a link error in
the linked-load path shipped unnoticed for weeks. Run steps 1–7 on an AVX2
machine and 8/8i on the 10.9 target until CI covers both.
```

- [ ] **Step 3: Add provenance at the bottom**

```markdown
## Provenance

Extracted from [Wowfunhappy/Mavericks-Porting-Resources](https://github.com/Wowfunhappy/Mavericks-Porting-Resources)
with its history intact. Wowfunhappy wrote the original emulator; the commit log
is the accurate record of who did what.
```

- [ ] **Step 4: Verify no hostname leaked**

```bash
grep -rniE 'bookair|\.local\b|ssh|oracle host' "$WORK/avxemu/README.md" \
  && echo "LEAK — remove it" || echo "clean"
```

Expected: `clean`. The AVX2 machine is described by its capability, never named.

- [ ] **Step 5: Commit**

```bash
cd "$WORK/avxemu"
git add README.md
git commit -m "docs: README for a repo that stands on its own

Says what avxemu is without assuming the reader arrived from the porting
monorepo, and states the two-machine build constraint up front. That
constraint is why a link error in the linked-load path went unnoticed for
weeks -- neither available host runs build.sh end to end -- so it belongs
in the README rather than in someone's memory."
```

---

### Task 4: LICENSE

**Files:**
- Create: `$WORK/avxemu/LICENSE`

**Interfaces:**
- Consumes: `$WORK/avxemu` from Task 3.
- Produces: an explicit licence file, since the source repo had none.

- [ ] **Step 1: Write it**

```
avxemu is dedicated to the public domain.

The authors waive all copyright and related or neighboring rights to this
work, worldwide, under CC0 1.0 Universal:
https://creativecommons.org/publicdomain/zero/1.0/

Where that dedication is not legally possible, this work is licensed under
the WTFPL: http://www.wtfpl.net/

Authors: Wowfunhappy <Wowfunhappy@gmail.com> (original emulator)
         Amitai Schleier <schmonz-web-git@schmonz.com>

Extracted from Wowfunhappy/Mavericks-Porting-Resources, whose author stated
the terms above for all original code in that repository
(https://github.com/Wowfunhappy/Mavericks-Porting-Resources/issues/4).
This project contains no third-party code.
```

- [ ] **Step 2: Verify the no-third-party-code claim still holds**

```bash
grep -rniE 'copyright|licen[cs]e|derived from|adapted from|SPDX' \
  "$WORK/avxemu/src" "$WORK/avxemu/test" "$WORK/avxemu/build.sh" \
  && echo "REVIEW these before claiming no third-party code" || echo "clean"
```

Expected: `clean`. If anything appears, amend the LICENSE to name it rather than
deleting the finding.

- [ ] **Step 3: Commit**

```bash
cd "$WORK/avxemu"
git add LICENSE
git commit -m "Add LICENSE: CC0, WTFPL fallback

Mavericks-Porting-Resources carries no LICENSE file; its author stated
the terms in issue #4 on 2026-09-08. Recording them here so a standalone
repo does not make readers go and find that thread."
```

---

### Task 5: Carry the unmerged branch

**Files:**
- Modify: `$WORK/avxemu` (adds a second branch)

**Interfaces:**
- Consumes: `$WORK/avxemu` from Task 4.
- Produces: branch `minspill-bmi-tier`, so deliberately-unmerged work is not
  silently dropped by the move.

- [ ] **Step 1: Confirm what is on it**

```bash
SRC=$HOME/Documents/code/trees/Mavericks-Porting-Resources
git -C "$SRC" log --oneline master..avxemu-minspill-bmi-tier -- avxemu
```

Expected: one commit, `feat(minspill): live-register BMI thunk tier + native-block
MULX (opt-in, default off)`.

- [ ] **Step 2: Extract it the same way**

```bash
WORK2=$(mktemp -d /tmp/avxemu-minspill.XXXXXX)
git clone --no-local "$SRC" "$WORK2/x"
git -C "$WORK2/x" checkout avxemu-minspill-bmi-tier
FILTER_BRANCH_SQUELCH_WARNING=1 \
  git -C "$WORK2/x" filter-branch -f --subdirectory-filter avxemu avxemu-minspill-bmi-tier
```

- [ ] **Step 3: Bring it across as a branch**

```bash
git -C "$WORK/avxemu" remote add tmp "$WORK2/x"
git -C "$WORK/avxemu" fetch tmp avxemu-minspill-bmi-tier:minspill-bmi-tier
git -C "$WORK/avxemu" remote remove tmp
git -C "$WORK/avxemu" log --oneline master..minspill-bmi-tier
```

Expected: the one minspill commit.

- [ ] **Step 4: Nothing to commit**

Branches are refs, not commits. Confirm both exist:

```bash
git -C "$WORK/avxemu" branch
```

---

### Task 6: Create the repo and push — REQUIRES EXPLICIT APPROVAL

**Files:**
- Creates: `github.com/ModernMavericks/avxemu`

**Interfaces:**
- Consumes: `$WORK/avxemu` from Task 5.
- Produces: the published repo.

**This task is outward-facing and irreversible in practice.** Do not run it
because the plan exists. Confirm with the user first, in this session.

- [ ] **Step 1: Confirm org access**

```bash
gh api user/orgs --jq '.[].login' | grep -x ModernMavericks
```

Expected: `ModernMavericks`.

- [ ] **Step 2: Final pre-push review**

```bash
git -C "$WORK/avxemu" log --oneline --all
git -C "$WORK/avxemu" ls-tree -r --name-only HEAD | head -20
du -sh "$WORK/avxemu/.git"
```

Expected: 16 commits on master (13 extracted + build/README/LICENSE), one on
`minspill-bmi-tier`, no stray files, and a `.git` well under 5 MB — if it is
tens of MB, Task 1 Step 4 was skipped and the whole monorepo is still in there.

- [ ] **Step 3: Create and push**

```bash
gh repo create ModernMavericks/avxemu --public \
  --description "AVX2/FMA/BMI emulation for pre-Haswell Macs running Mac OS X 10.9"
git -C "$WORK/avxemu" remote add origin https://github.com/ModernMavericks/avxemu.git
git -C "$WORK/avxemu" push -u origin master
git -C "$WORK/avxemu" push origin minspill-bmi-tier
```

- [ ] **Step 4: Verify what landed**

```bash
gh repo view ModernMavericks/avxemu --json name,description,defaultBranchRef
gh api repos/ModernMavericks/avxemu/commits --jq 'length'
```

---

### Task 7: File the thread-safety work as the first issue

**Files:**
- Reads: `docs/proposals/avxemu-thread-safe-patching.md` (in `mavericks-claude-ongoing`)

**Interfaces:**
- Consumes: the published repo from Task 6.
- Produces: issue #1, so the repo opens with a real defect rather than a
  housekeeping commit.

- [ ] **Step 1: File it**

```bash
gh issue create --repo ModernMavericks/avxemu \
  --title "Live code patching is not thread-safe: it kills any multithreaded process" \
  --body-file <(sed -n '/^## The bug/,$p' \
    "$HOME/Documents/code/trees/mavericks-claude-ongoing/docs/proposals/avxemu-thread-safe-patching.md")
```

- [ ] **Step 2: Check the body for the oracle hostname**

```bash
gh issue view 1 --repo ModernMavericks/avxemu --json body -q .body \
  | grep -niE 'bookair|ssh' && echo "EDIT THE ISSUE" || echo "clean"
```

- [ ] **Step 3: Record the move where the next session will look**

Update `mavericks-claude-ongoing`: point
`docs/proposals/avxemu-thread-safe-patching.md` at the new issue, and note in
the memory file `avxemu-repo-takeover.md` that avxemu now lives at
`ModernMavericks/avxemu`, with the toolkit still pending PRs #11 and #12.

```bash
cd "$HOME/Documents/code/trees/mavericks-claude-ongoing"
git add -A && git commit -m "docs: avxemu now lives at ModernMavericks/avxemu"
```

---

## Self-Review

**Spec coverage.** Extraction mechanics → Task 1. `build.sh` externals → Task 2.
README and the oracle constraint → Task 3. Licensing → Task 4. The unmerged
branch → Task 5. Repo creation → Task 6. First issue → Task 7. The spec's
sequencing constraint (toolkit waits for PRs #11/#12) is a Global Constraint and
deliberately has no task here — it belongs to the toolkit plan.

**Placeholders.** None: every step carries the command or the text to write.

**Consistency.** `$WORK/avxemu` is the repo throughout; `$WORK2` appears only in
Task 5 and is discarded. Commit counts are stated once (13 extracted, 16 at
push) and used consistently.
