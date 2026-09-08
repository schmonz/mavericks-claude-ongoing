# ModernMavericks/macho-tools Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lift the nine Mach-O tools out of `Mavericks-Porting-Resources` into a
standalone `ModernMavericks/macho-tools` repo with history intact, starting from
a base that already contains the prove-it-or-refuse work rather than one that
needs it re-applied.

**Architecture:** `git filter-branch --index-filter` on a throwaway clone of the
`macho-grow-verify-invariant` branch — not `master`, and not
`--subdirectory-filter`, because the files live at the repo root. Then a build
script (there has never been one), a README, and a LICENSE.

**Tech Stack:** git 2.54.0, BSD userland on macOS 10.9, clang (Apple LLVM 6.0),
`gh` CLI authenticated over HTTPS.

**Spec:** `docs/superpowers/specs/2026-09-08-modernmavericks-claude-decomposition-design.md`

**Position in the sequence: FIRST.** `avxemu` follows
(`docs/superpowers/plans/2026-09-08-avxemu-repo-extraction.md`), then the Claude
repo. This one goes first because the toolkit proposal wants avxemu to consume
this repo's `live.h`, so the depended-upon repo should exist first.

## Global Constraints

- **The extraction changes no code.** The build script, README and LICENSE are
  additions; not one line of the nine tools changes in this plan.
- **Extract from `macho-grow-verify-invariant`, not `master`.** That branch
  carries PR #11 and PR #12 — 27 commits versus 18 — so the new repo starts
  current. Extracting from `master` would start it nine commits behind.
- **Licence:** public domain / CC0 / WTFPL, per Wowfunhappy in
  `Wowfunhappy/Mavericks-Porting-Resources` issue #4 (closed 2026-09-08).
  `patch_macho.c` and `fix_macho.c` are substantially his; the LICENSE and README
  say so.
- **`git subtree` and `git-filter-repo` are absent** on this box; `filter-branch`
  is present. BSD `xargs` has no `-r` and BSD `grep` no `-z`, so the GNU
  index-filter recipes fail *silently* — the filter errors, nothing is filtered,
  and you get an unfiltered clone that looks like success. Use the
  `git rm --cached -r . && git reset $GIT_COMMIT -- <paths>` form below, which was
  verified on this machine.
- **Do not modify `Mavericks-Porting-Resources` in this plan.** Removing the
  originals is a later, coordinated PR — his `install.sh` ships binaries built
  from them.
- **Do not close PRs #11 or #12.** Task 6 comments; the decision is Wowfunhappy's.
- **Repo creation and pushing are outward-facing.** Task 5 requires explicit
  approval at execution time.
- **Do not copy code from `Wowfunhappy/insert_dylib`.** Neither it nor its parent
  `tyilo/insert_dylib` states a licence, so the default is all rights reserved
  and copying would break this repo's CC0 dedication. Wowfunhappy can relicense
  his own additions; he cannot relicense tyilo's base. **Ideas are free; code is
  not.** See Task 7.

---

## File Structure

The nine files carried verbatim:

| file | job |
|---|---|
| `patch_macho.c` | chained fixups → `LC_DYLD_INFO_ONLY` |
| `change_dylib.c` | dylib/rpath editing, ordinal renumbering, `-strip-lc`, `-grow`, and the pre-write verify gate |
| `macho_grow.h` | header growth by lowering the image base, every base-relative re-baser, `mg_verify`, `mg_plausible` |
| `fix_macho.c` | `-change` + strip build version, fat binaries |
| `add_version_min.c` | append `LC_VERSION_MIN_MACOSX` |
| `rename_segment.c` | `__DATA_CONST` → `__DATA` |
| `retag_swift_classes.c` | move the is-Swift tag to the legacy bit |
| `macho_grow_test.c` | hermetic tests for the grow path |
| `change_dylib_test.sh` | builds real dylibs, rewrites a real binary, runs it |

Added on top:

| file | responsibility |
|---|---|
| `build.sh` | *created* — build all six tools, run both suites. The repo has never had one |
| `README.md` | *created* — the repo has none of its own |
| `LICENSE` | *created* |

---

### Task 1: Extract with history, and prove the result is faithful

**Files:**
- Create: `$WORK/macho-tools`
- Read: `~/Documents/code/trees/Mavericks-Porting-Resources`

**Interfaces:**
- Produces: `$WORK/macho-tools`, a git repo with 27 commits whose nine files are
  byte-identical to those on `macho-grow-verify-invariant`. Every later task
  works inside it.

- [ ] **Step 1: Clone to a throwaway**

```bash
SRC=$HOME/Documents/code/trees/Mavericks-Porting-Resources
WORK=$(mktemp -d /tmp/macho-tools-extract.XXXXXX)
git clone --no-local "$SRC" "$WORK/macho-tools"
git -C "$WORK/macho-tools" checkout macho-grow-verify-invariant
```

`--no-local` copies objects rather than hardlinking them, so nothing here can
damage the source repo's object store.

- [ ] **Step 2: Run the extraction**

```bash
FILTER_BRANCH_SQUELCH_WARNING=1 \
  git -C "$WORK/macho-tools" filter-branch -f --prune-empty \
  --index-filter 'git rm --cached -q -r --ignore-unmatch . && git reset -q $GIT_COMMIT -- patch_macho.c change_dylib.c macho_grow.h fix_macho.c add_version_min.c rename_segment.c retag_swift_classes.c macho_grow_test.c change_dylib_test.sh' \
  macho-grow-verify-invariant
```

Expected: a `Rewrite …` progress run, then
`Ref 'refs/heads/macho-grow-verify-invariant' was rewritten`.

`--prune-empty` drops the commits that touched none of the nine files. Without
it the history is padded with empty commits carrying unrelated messages.

- [ ] **Step 3: Rename the branch to `main` and drop the leftovers**

```bash
cd "$WORK/macho-tools"
git branch -m macho-grow-verify-invariant main
git remote remove origin
rm -rf .git/refs/original
git reflog expire --expire=now --all
git gc --prune=now --quiet
du -sh .git
```

Expected: `.git` comfortably under 1 MB. **If it is tens of MB, the gc did not
take and the whole monorepo is still in the object store** — do not push it.

- [ ] **Step 4: Verify fidelity — this is the test**

```bash
SRC=$HOME/Documents/code/trees/Mavericks-Porting-Resources
echo "commits: $(git -C "$WORK/macho-tools" log --oneline | wc -l)   want 27"
git -C "$WORK/macho-tools" ls-tree --name-only HEAD
for f in patch_macho.c change_dylib.c macho_grow.h fix_macho.c add_version_min.c \
         rename_segment.c retag_swift_classes.c macho_grow_test.c change_dylib_test.sh; do
  git -C "$SRC" show "macho-grow-verify-invariant:$f" \
    | diff -q - "$WORK/macho-tools/$f" >/dev/null \
    && echo "  same  $f" || echo "  DIFFERS  $f"
done
```

Expected: 27 commits; exactly the nine files; every line reads `same`.

**If any file differs, stop.** The extraction is wrong; do not continue.

- [ ] **Step 5: Verify the tests still pass**

```bash
cd "$WORK/macho-tools"
clang -O2 -Wno-unused-function -o /tmp/mgt macho_grow_test.c && /tmp/mgt
sh change_dylib_test.sh 2>&1 | tail -1
```

Expected: `macho_grow_test: all cases pass` and
`change_dylib_test: all cases pass`.

- [ ] **Step 6: Commit nothing**

The history is the deliverable.

```bash
git -C "$WORK/macho-tools" status --short    # expect no output
```

---

### Task 2: A build script, because there has never been one

**Files:**
- Create: `$WORK/macho-tools/build.sh`

**Interfaces:**
- Consumes: `$WORK/macho-tools` from Task 1.
- Produces: `sh build.sh` builds all six tools into `build/` and runs both
  suites; `CC` and `OUT` are overridable.

Upstream never needed this: `install.sh` downloads prebuilt binaries from the
CDN, and the tools were compiled by hand on one machine. A repo that stands
alone needs a way to build itself.

- [ ] **Step 1: Confirm the flags, because one file is fussy**

```bash
cd "$WORK/macho-tools"
for t in patch_macho change_dylib add_version_min fix_macho rename_segment retag_swift_classes; do
  clang -O2 -Wall -o /tmp/probe-$t $t.c 2>/dev/null && echo "  OK   $t" || echo "  FAIL $t"
done
clang -O2 -Wall -std=c11 -o /tmp/probe-pm patch_macho.c 2>/dev/null \
  && echo "  c11 also fine" || echo "  patch_macho does NOT build with -std=c11 (anonymous structs)"
```

Expected: all six `OK`, and the `-std=c11` probe reports that `patch_macho` does
not build with it. That is why the script below sets no `-std`.

- [ ] **Step 2: Write it**

```sh
#!/bin/sh
# Build every tool and run every test.
#
#   ./build.sh              build into ./build, then run both suites
#   OUT=/tmp/x ./build.sh   build somewhere else
#
# No -std: patch_macho.c uses anonymous struct assignment that clang rejects
# under -std=c11 but accepts in its default gnu dialect. Everything here is
# built with the stock 10.9 toolchain and has no dependencies.
set -e
CC="${CC:-clang}"
OUT="${OUT:-build}"
mkdir -p "$OUT"

echo "[1] tools..."
for t in patch_macho change_dylib add_version_min fix_macho rename_segment retag_swift_classes; do
    "$CC" -O2 -Wall -o "$OUT/$t" "$t.c"
    echo "    $OUT/$t"
done

echo "[2] macho_grow_test (hermetic: grow, re-basers, verify, plausibility)..."
"$CC" -O2 -Wno-unused-function -o "$OUT/macho_grow_test" macho_grow_test.c
"$OUT/macho_grow_test"

echo "[3] change_dylib_test (builds real dylibs, rewrites a real binary, RUNS it)..."
sh change_dylib_test.sh

echo "OK"
```

- [ ] **Step 3: Run it**

```bash
cd "$WORK/macho-tools" && chmod +x build.sh && sh build.sh 2>&1 | tail -6
```

Expected: six tool paths, then both suites passing, then `OK`.

- [ ] **Step 4: Keep build output out of git**

```bash
cd "$WORK/macho-tools"
printf 'build/\n' > .gitignore
git status --short     # expect only build.sh and .gitignore as untracked
```

- [ ] **Step 5: Commit**

```bash
cd "$WORK/macho-tools"
git add build.sh .gitignore
git commit -m "Add build.sh: build every tool, run every test

The repo these came from never had one -- install.sh downloads prebuilt
binaries, and the tools were compiled by hand on one machine. A repo that
stands alone needs to be able to build itself.

No -std: patch_macho.c assigns to an anonymous struct, which clang rejects
under -std=c11 and accepts in its default dialect. Found by trying it
rather than by assuming the six were uniform."
```

---

### Task 3: README

**Files:**
- Create: `$WORK/macho-tools/README.md`

**Interfaces:**
- Consumes: `$WORK/macho-tools` from Task 2.
- Produces: a README explaining what the tools are for, why they exist when
  `install_name_tool` also exists, and where the history came from.

- [ ] **Step 1: Write it**

```markdown
# macho-tools

Mach-O surgery for hosts too old to have any. Builds with the stock Mac OS X
10.9 clang, has no dependencies, and edits binaries produced by toolchains
fifteen years newer.

| tool | job |
|---|---|
| `patch_macho` | rewrite chained fixups as `LC_DYLD_INFO_ONLY`, so 10.9's dyld can load the image |
| `change_dylib` | edit `LC_LOAD_DYLIB` / `LC_RPATH`: change, delete, add, insert, re-export, with library-ordinal renumbering; `-strip-lc`; `-grow` |
| `add_version_min` | append `LC_VERSION_MIN_MACOSX` |
| `fix_macho` | change install names and strip build version, including in fat binaries |
| `rename_segment` | `__DATA_CONST` → `__DATA`, so 10.9's libobjc finds the metadata |
| `retag_swift_classes` | move the is-Swift tag from the stable-ABI bit to the legacy one |

## Building

    ./build.sh        builds into ./build and runs both test suites

## Why not install_name_tool

On these binaries, 10.9's `install_name_tool` **refuses to open the file**:

    install_name_tool: file not in an order that can be processed (dyld_info out of place)

It rebuilds `__LINKEDIT` and expects the 2013-era ordering of its pieces; modern
linkers emit a different order, so it bails before touching anything. These
tools never move a byte of file data — they edit within existing header padding,
which is why `-strip-lc` and `-grow` exist and why a replacement path that is
too long is an error here and a non-event with Apple's tool.

## Prove it or refuse

Growing the header lowers the image base, which invalidates every structure that
stores an offset *from* that base: the `LC_FUNCTION_STARTS` leading delta,
`__TEXT,__init_offsets`, the export trie, `LC_DATA_IN_CODE`, and compact unwind.
Each is re-based; anything unrecognised is refused rather than grown past.

Two independent checks back that up. `mg_verify` proves every base-relative
structure resolves to the same address after the grow as before. `mg_plausible`
asks a different question of the finished file — do initializers and unwind
entries still land on an address `LC_FUNCTION_STARTS` lists — and needs no
"before" image, so `change_dylib` runs it before writing and refuses rather than
committing a bad rewrite. `MACHO_NO_VERIFY=1` opts out.

That gate exists because every defect found in this code has been a silent
success: the tool reported OK and the binary died in the loader, or worse, did
not.

## Provenance

Extracted with history from
[Wowfunhappy/Mavericks-Porting-Resources](https://github.com/Wowfunhappy/Mavericks-Porting-Resources).
`patch_macho` and `fix_macho` are substantially Wowfunhappy's; the growth,
re-basers, ordinal renumbering and verification are Amitai Schleier's. The commit
log is the accurate record.

Four commits in that history also touched files that stayed behind, so their
messages mention unrelated work ("Electron stuff"). The changes themselves are
correct; only the messages are wider than the diff.
```

- [ ] **Step 2: Sanity-check the claims you just made**

```bash
cd "$WORK/macho-tools"
grep -c 'MACHO_NO_VERIFY' change_dylib.c      # expect 1
grep -c 'mg_plausible\|mg_verify' macho_grow.h # expect > 5
```

If either is zero the README is describing a different tree than the one you
extracted. Stop and find out why.

- [ ] **Step 3: Commit**

```bash
cd "$WORK/macho-tools"
git add README.md
git commit -m "docs: README for a repo that stands on its own

Says what the tools do, why install_name_tool is not an alternative on
these binaries (it refuses to open them), and what the verify gate is for.
Also notes that four commits in the history carry messages wider than
their diffs, since they touched files that stayed behind."
```

---

### Task 4: LICENSE

**Files:**
- Create: `$WORK/macho-tools/LICENSE`

**Interfaces:**
- Consumes: `$WORK/macho-tools` from Task 3.
- Produces: an explicit licence, since the source repo had none.

- [ ] **Step 1: Write it**

```
macho-tools is dedicated to the public domain.

The authors waive all copyright and related or neighboring rights to this
work, worldwide, under CC0 1.0 Universal:
https://creativecommons.org/publicdomain/zero/1.0/

Where that dedication is not legally possible, this work is licensed under
the WTFPL: http://www.wtfpl.net/

Authors: Wowfunhappy <Wowfunhappy@gmail.com>
         Amitai Schleier <schmonz-web-git@schmonz.com>

Extracted from Wowfunhappy/Mavericks-Porting-Resources, whose author stated
the terms above for all original code in that repository
(https://github.com/Wowfunhappy/Mavericks-Porting-Resources/issues/4).
```

- [ ] **Step 2: Check for third-party provenance before claiming there is none**

```bash
grep -rniE 'copyright|licen[cs]e|derived from|adapted from|SPDX|LIEF|llvm' \
  "$WORK/macho-tools"/*.c "$WORK/macho-tools"/*.h
```

Expected: hits in `macho_grow.h` comments crediting **LIEF** and
**llvm-objcopy** as the sources of the *technique* (the exhaustive offset-field
list), not of any code. That is study, not derivation, and the LICENSE above is
still accurate. Read the surrounding comment and confirm before proceeding — if
any file turns out to contain copied code, name it in the LICENSE rather than
deleting the finding.

- [ ] **Step 3: Commit**

```bash
cd "$WORK/macho-tools"
git add LICENSE
git commit -m "Add LICENSE: CC0, WTFPL fallback

Mavericks-Porting-Resources carries no LICENSE file; its author stated the
terms in issue #4 on 2026-09-08."
```

---

### Task 5: Create the repo and push — REQUIRES EXPLICIT APPROVAL

**Files:**
- Creates: `github.com/ModernMavericks/macho-tools`

**Interfaces:**
- Consumes: `$WORK/macho-tools` from Task 4.
- Produces: the published repo.

**Outward-facing and irreversible in practice.** Confirm with the user in this
session first; the plan existing is not approval.

- [ ] **Step 1: Confirm org access**

```bash
gh api user/orgs --jq '.[].login' | grep -x ModernMavericks
```

- [ ] **Step 2: Final pre-push review**

```bash
cd "$WORK/macho-tools"
git log --oneline | head -12
git ls-tree --name-only HEAD
du -sh .git
sh build.sh 2>&1 | tail -3
```

Expected: 30 commits (27 extracted + build/README/LICENSE), twelve files, `.git`
under 1 MB, and `build.sh` ending in `OK`.

- [ ] **Step 3: Create and push**

```bash
gh repo create ModernMavericks/macho-tools --public \
  --description "Mach-O surgery for Mac OS X 10.9: load-command editing, chained-fixups conversion, header growth"
git -C "$WORK/macho-tools" remote add origin https://github.com/ModernMavericks/macho-tools.git
git -C "$WORK/macho-tools" push -u origin main
```

- [ ] **Step 4: Verify what landed**

```bash
gh repo view ModernMavericks/macho-tools --json name,defaultBranchRef
gh api repos/ModernMavericks/macho-tools/commits --jq 'length'
```

---

### Task 6: Tell Wowfunhappy, and leave PRs #11 and #12 to him

**Files:**
- None locally; comments on two PRs.

**Interfaces:**
- Consumes: the published repo from Task 5.

**Do not close these PRs.** #11 is a silent-corruption fix for code he still
ships: `install.sh` builds `patch_macho`, `change_dylib` and `add_version_min`
from his repo, so until he adopts `macho-tools` his artifacts keep the defect.
Whether he merges them or switches to consuming the new repo is his call.

- [ ] **Step 1: Comment on both**

```bash
for n in 11 12; do
  gh pr comment $n --repo Wowfunhappy/Mavericks-Porting-Resources --body \
"Following up on the avxemu handoff: these tools now also live at
https://github.com/ModernMavericks/macho-tools, extracted with full history —
the commits in this PR are already in that repo's history.

Leaving this open rather than closing it, because it is your call which you
prefer: merge here, or consume macho-tools and let this go. Worth noting for #11
specifically that it fixes silent corruption in code \`install.sh\` still builds
from this repo, so if you would rather not adopt a new dependency yet, merging it
here is the safer of the two.

Happy to open a PR removing the originals from this repo whenever you want it,
but not before you have decided."
done
```

- [ ] **Step 2: Record the move where the next session will look**

Update `mavericks-claude-ongoing`: note in `docs/proposals/macho-toolkit.md` that
the repo now exists, and in the memory file `avxemu-repo-takeover.md` that
`macho-tools` has moved and `avxemu` is next.

```bash
cd "$HOME/Documents/code/trees/mavericks-claude-ongoing"
git add -A && git commit -m "docs: the Mach-O tools now live at ModernMavericks/macho-tools"
```

---

---

### Task 7: Close the gap with `Wowfunhappy/insert_dylib`

**Files:**
- Create: `$WORK/macho-tools/docs/prior-art.md`
- Produces: three tracked issues on **our own** repo.

`Wowfunhappy/insert_dylib` (a fork of `tyilo/insert_dylib`, last touched
2026-09-06) independently grew a header-expansion path — `6d3aa61`, "Handle
binaries without enough space. (Vibecoded)", +701 lines — using **the same
geometry we do**: lower `__TEXT`'s vmaddr, then fix up what that invalidates. He
is open to switching to whatever we build, so the goal is that switching costs
him nothing: **no capability of his should be missing from ours.**

Measured 2026-09-08 against his `main.c` at HEAD:

| | insert_dylib | macho-tools |
|---|---|---|
| export trie | **rebuilds it** — handles a ULEB that widens | in place at original width; **refuses** if one would widen |
| 32-bit (`LC_SEGMENT`) | yes | **no** — 64-bit only |
| fat binaries in the rewrite path | yes (12 refs) | **no** in `change_dylib`; only `fix_macho` handles fat |
| `S_INIT_FUNC_OFFSETS` | yes | yes |
| `LC_FUNCTION_STARTS` leading delta | no | yes |
| `LC_DATA_IN_CODE` contents | no | yes |
| `__TEXT,__unwind_info` | no | yes |
| unknown load command | proceeds | refuses |
| post-transform verification | none | `mg_verify` + `mg_plausible` |

**Three real gaps on our side.** They are all "his tool can, ours refuses or
cannot" — the kind that would make switching a downgrade for him.

- [ ] **Step 1: Re-verify before recording any of it**

```bash
T=$(mktemp -d)
gh api repos/Wowfunhappy/insert_dylib/contents/insert_dylib/main.c --jq '.content' \
  | base64 -D > "$T/main.c"
for t in trie_parse 'LC_SEGMENT\b' fat_arch unwind data_in_code_entry S_INIT_FUNC_OFFSETS; do
  printf "  %-24s %s\n" "$t" "$(grep -cE "$t" "$T/main.c")"
done
```

Expected as of 2026-09-08: `trie_parse` 3, `LC_SEGMENT\b` 2, `fat_arch` >0,
`unwind` 0, `data_in_code_entry` 0, `S_INIT_FUNC_OFFSETS` 4. **He was working on
this two days before this plan was written — if the numbers moved, redo the
table.**

- [ ] **Step 2: Record it in the repo, as prior art rather than as a scoreboard**

Write `$WORK/macho-tools/docs/prior-art.md` containing the table above, plus:

```markdown
## Why this matters

Two independent implementations of the same trick is evidence the trick is
right. It also means neither is finished: each covers cases the other misses,
and the union is what the tool should be.

The three gaps above are tracked as issues. Until they are closed, macho-tools
is not a drop-in replacement for insert_dylib on 32-bit or fat inputs, or on a
binary whose export trie needs a wider ULEB — and it should not be described as
one.

## On taking the code

Neither `Wowfunhappy/insert_dylib` nor `tyilo/insert_dylib` states a licence, so
the default is all rights reserved and this repo is CC0. The trie rebuild is
Wowfunhappy's own addition (`6d3aa61`), so it is his to relicense — he has
already stated CC0/WTFPL terms for his original code elsewhere and offered
written consent for other licences on request. **Ask before taking.** The
32-bit and fat handling is closer to tyilo's base; reimplement that rather than
copy it.
```

- [ ] **Step 3: File the three gaps as issues on our own repo**

```bash
gh issue create --repo ModernMavericks/macho-tools \
  --title "Export trie: rebuild when an address's ULEB would widen, instead of refusing" \
  --body "macho_grow re-encodes each export address at its ORIGINAL byte width, so
the trie never changes size and no __LINKEDIT offset moves. Measured across all
670 entries of Claude Code 2.1.263 at 4K/8K/16K grows, zero need a wider
encoding — so today this costs nothing.

It is still a refusal where insert_dylib succeeds. The general fix is to rebuild
the trie and let it change size, extending __LINKEDIT accordingly, and to fall
back to that only when the in-place path reports a widening. That keeps the
cheap path cheap.

See docs/prior-art.md. The existing implementation is Wowfunhappy's own commit
6d3aa61 in insert_dylib, so it is his to relicense if we would rather take than
rewrite — ask first, the repo states no licence."

gh issue create --repo ModernMavericks/macho-tools \
  --title "32-bit Mach-O: macho_grow refuses; insert_dylib handles it" \
  --body "mg_grow_header requires a 64-bit Mach-O and refuses otherwise.
insert_dylib handles LC_SEGMENT as well as LC_SEGMENT_64. Nothing in the Claude
Code pipeline needs it, so this is about being a superset rather than about a
current failure. See docs/prior-art.md."

gh issue create --repo ModernMavericks/macho-tools \
  --title "Fat binaries: change_dylib handles only thin; fix_macho and insert_dylib handle fat" \
  --body "fix_macho.c walks fat_arch; change_dylib.c does not, so the rewriting
verbs are thin-only. insert_dylib handles fat throughout. Converging fix_macho
and change_dylib is already the plan in the toolkit proposal — fat support is
one of the two things fix_macho brings to that merge. See docs/prior-art.md."
```

- [ ] **Step 4: Commit the prior-art note**

```bash
cd "$WORK/macho-tools"
git add docs/prior-art.md
git commit -m "docs: what insert_dylib does that this does not, yet

Wowfunhappy's insert_dylib fork independently grew the same
lower-the-image-base expansion trick, and is open to switching to this.
Switching should not cost him anything, so the three things it does and
this does not -- export-trie rebuild on ULEB widening, 32-bit, and fat
binaries in the rewrite path -- are written down and tracked rather than
left as a surprise.

Recorded as prior art, not a scoreboard: two independent implementations
converging is evidence the approach is right, and each covers cases the
other misses."
```

## Self-Review

**Spec coverage.** Extraction from the feature branch → Task 1. The missing build
script → Task 2. README and the `install_name_tool` rationale → Task 3.
Licensing → Task 4. Repo creation → Task 5. PR handling, which the spec insists
must not be a silent close → Task 6. The spec's `live.h` question is deliberately
absent: it is follow-on work once both repos exist.

**Placeholders.** None; every step carries its command or its text.

**Consistency.** `$WORK/macho-tools` throughout. Commit counts stated once — 27
extracted, 30 at push — and used consistently. The branch is renamed to `main` in
Task 1 Step 3 and referred to as `main` thereafter.
