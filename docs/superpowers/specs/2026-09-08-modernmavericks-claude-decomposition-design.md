# ModernMavericks/claude: decomposing Mavericks-Porting-Resources

**Status:** design, 2026-09-08. Green light from Wowfunhappy for all three repos.

Claude Code on 10.9 currently depends on work scattered across three places:
an emulator and a set of Mach-O tools living in **someone else's** monorepo, and
a wrapper plus its evidence living in a personal notes repo. This turns that
into three ModernMavericks repos with history intact, and makes the Claude one
the thing a user actually installs.

## Why now, and why this shape

Three forcing conditions arrived together:

1. **Licensing is settled.** Issue #4, closed 2026-09-08: anything original in
   Mavericks-Porting-Resources is public domain / CC0 / WTFPL, code from other
   projects keeps its own licence, and Wowfunhappy will grant written consent for
   any other licence on request. avxemu carries no third-party provenance markers
   at all (checked: no copyright, licence, "derived from" or SPDX lines in
   `src/`, `test/`, `build.sh` or `README.md`).
2. **Wowfunhappy invited the avxemu takeover** and has green-lit a Claude repo
   built from these ingredients.
3. **The work outgrew the container.** `change_dylib.c` has nearly tripled;
   avxemu has its own test suite, its own oracle requirement and its own open
   defect. Both are now maintained almost entirely by one person who does not own
   the repo they live in.

The repo count follows **ownership**, not function — the same argument
`docs/proposals/macho-toolkit.md` settles for the toolkit.

## The three repos

| repo | contents | source |
|---|---|---|
| **ModernMavericks/avxemu** | the AVX2/FMA/BMI emulator: `src/`, `test/`, `build.sh`, `README.md` | `Mavericks-Porting-Resources/avxemu/` |
| **ModernMavericks/machotools** | `patch_macho.c`, `change_dylib.c`, `macho_grow.h`, `fix_macho.c`, `add_version_min.c`, `rename_segment.c`, `retag_swift_classes.c`, `macho_grow_test.c`, `change_dylib_test.sh` | Mavericks-Porting-Resources root |
| **ModernMavericks/claude** | the wrapper, its rebase script, the local-build script, the spin canary, the findings and procedures | `mavericks-claude-ongoing` + upstream's `install.sh` wrapper |

Shape settled for the middle one in `docs/proposals/macho-toolkit.md`: one repo,
first-party, no `UPSTREAM_VERSION`, because it is its own upstream.

**Naming correction to that proposal.** It calls the repos `mavericks-machotools`
and `mavericks-avxemu`. The org does not name repos that way — checked:
`ModernMavericks/golang`, `/clang`, `/tailscale`, `/openssh` are all bare. The
`mavericks-` prefix belongs to the *package* a repo produces, not the repo. So:
repos `machotools` and `avxemu`, packages `mavericks-machotools` and
`mavericks-avxemu`. The proposal should be corrected rather than followed here.

## Extraction mechanics — verified, not assumed

This box has **no `git subtree` and no `git-filter-repo`**; `git filter-branch`
is present (git 2.54.0). BSD `xargs` has no `-r` and BSD `grep` no `-z`, so the
GNU index-filter recipes found online fail silently — the filter errors, nothing
is filtered, and the result looks like a successful clone of everything. Both
extractions below were run end to end in a throwaway and checked.

**avxemu** — a clean subdirectory, so `--subdirectory-filter` applies:

| | |
|---|---|
| commits on master | 13 (26 across all branches) |
| commits touching avxemu *and* something else | **0** |
| merge commits in its history | **0** |
| `#include`s outside its own tree | **0** |
| result | `README.md build.sh src test` at root, authors and dates preserved, builds standalone |

**machotools** — files at the repo root, so it needs an index-filter:

| | |
|---|---|
| commits touching the nine files | 14 (10 pure, 4 mixed with `framework-stubs/` and `mavericks-legacy-support/`) |
| result after `--prune-empty` | 18 commits, the nine files at root |
| verification | compiles clean; `macho_grow_test` and `change_dylib_test` both pass in the extracted repo |

The four mixed commits survive, reduced to their toolkit changes. Their messages
still mention unrelated work ("Electron stuff"); cosmetic, not a correctness
problem.

`filter-branch` rewrites SHAs, so neither new repo shares commit IDs with
Mavericks-Porting-Resources. Nothing can be cherry-picked between them by hash
afterwards — inherent to any extraction, worth knowing before it surprises
someone.

## Sequencing, and the one hard constraint

**avxemu first. The toolkit cannot go yet.**

PRs #11 and #12 are open against Mavericks-Porting-Resources and touch exactly
`macho_grow.h`, `macho_grow_test.c` and `change_dylib.c` — the extraction set.
Extracting the toolkit before they merge orphans them: the branches they came
from would target a repo that no longer contains the files. avxemu has no open
PRs and no pending work in flight, so it can move today.

Order:

1. **ModernMavericks/avxemu** — now. Its first issue is already written:
   `docs/proposals/avxemu-thread-safe-patching.md`.
2. **PRs #11 and #12 merge** into Mavericks-Porting-Resources.
3. **ModernMavericks/machotools** — extract, then remove the originals
   from Mavericks-Porting-Resources in a coordinated PR, since his `install.sh`
   builds `patch_macho` / `change_dylib` / `add_version_min` from them.
4. **ModernMavericks/claude** — assembled last, because it consumes the other
   two.

Removing the originals is the step that can break someone else's build, so it is
a PR with a note, never a push.

## What `docs/proposals/macho-toolkit.md` already decided

That proposal is the authority on the toolkit and predates this one. Four of its
conclusions bear directly on this plan:

- **avxemu will eventually depend on machotools.** The proposal wants avxemu to
  consume `live.h` — the header-only, malloc-free subset — via a CMake package,
  under the family's consume-don't-vendor rule. Today avxemu has *zero* includes
  outside its own tree, which is what makes this extraction trivial; that changes
  the day `live.h` lands. The proposal names the fallback too: avxemu keeps its
  own small structure walks, "which is what it does today and which costs
  little". **Extract first, decide `live.h` later** — nothing here forecloses it.
- **Its step 4, `verify` wired into the wrapper before its `mv`, is already
  done** (PR #12, `change_dylib` verifies before writing). Its sequencing is
  partly overtaken by events and should be re-read, not replayed.
- **It flagged ownership as "worth settling before the first commit, not
  after."** Settled 2026-09-08: licence in issue #4, and Wowfunhappy's green
  light for all three repos.
- **"Two repos total, not four"** is about not splitting each project into
  source plus packaging repos. It is not an argument against a third repo for
  Claude, which the proposal was not considering.

## The family house shape

ModernMavericks repos are not bare source drops. `ModernMavericks/golang`
carries `CMakeLists.txt`, `.github/` (CI), `INGREDIENTS.md`, `release-notes/`,
`scripts/`, `tests/` and a `CLAUDE.md`. Neither extraction produces that, and
neither should: the move's whole value is that nothing changed but the address.
Adopting the house shape — CMake against shared-cmake, `release.yml`, a `.pkg`,
the Sparkle appcast — is follow-on work per repo, and it is where the GHA
question below gets answered.

## Per-repo work beyond the extraction

**avxemu.** `build.sh` has exactly three references outside its own tree, all
already env-overridable: `PUBLIC` defaults to `/Users/Jonathan/Developer/…` (his
machine) and `CLAUDE_BIN` defaults to a stale `2.1.166`. Both need honest
defaults. The README must state the constraint that steps 3, 4 and 6b need real
AVX2 hardware for ground truth and cannot run on the target platform — that gap
is how `avxemu-rebind-when-linked` shipped a link error unnoticed for weeks. An
AVX2 machine is available locally; **its name stays out of the repo.**

**machotools.** Needs the family shape (shared-cmake, `release.yml`,
`.pkg`, Sparkle appcast) and the `macho9` CLI grammar already settled in the
proposal. `verify` doubles as the in-CI characterization proof: commit a small
pristine chained-fixups fixture, run the pipeline over it, assert the invariants.

**claude.** The largest open design question, deliberately deferred: what a user
installs, how it relates to `mavericksforever.com/claude/install.sh`, and whether
the four local wrapper edits become the wrapper or stay as a rebase script
against upstream's.

## Open questions

- **GitHub Actions.** The family builds in CI; avxemu's oracles need AVX2, which
  a standard runner has. Getting steps 1–7 running on GHA would be a real
  improvement over today, where neither available machine runs `build.sh` end to
  end. Deferred, not dismissed.
- **Does Mavericks-Porting-Resources keep a copy?** Removing avxemu changes how
  Wowfunhappy builds `libavxemu.dylib` for the CDN. Needs his agreement on the
  handoff, not just a merged PR.
- **Publishing.** `build.sh install` copies into his public dir today. Either
  mavericksforever.com pulls from the new repo, or the new repo cuts releases and
  he consumes them.

## Non-goals

Rewriting avxemu or the toolkit while moving them; changing the emulator's
behaviour; the `macho9` CLI redesign; and the thread-safety fix. Each is real
work with its own plan, and none of it belongs in a move whose entire value is
that nothing changed but the address.
