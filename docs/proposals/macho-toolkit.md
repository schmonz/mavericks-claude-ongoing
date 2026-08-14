# Proposal: extract the Mach-O surgery into one toolkit

Discussion doc for `Mavericks-Porting-Resources`. Not a plan of record.

## What exists today

Seven pieces of code rewrite or read Mach-O binaries, in two families that
never share a line.

**File rewriters** — read a whole file into a buffer, mutate, write back:

| file | lines | job |
|---|---|---|
| `patch_macho.c` | 356 | chained fixups → `LC_DYLD_INFO_ONLY`; strips exports trie + build version; extends `__LINKEDIT` |
| `change_dylib.c` | 238 | `-change` / `-delete` / `-reexport` / `-add` / `-insert`, library-ordinal renumbering |
| `macho_grow.h` | 376 | grow the header pad by lowering the image base; the exhaustive file-offset bump table; function-starts and `__init_offsets` re-base |
| `fix_macho.c` | 194 | `-change` + strip build version, **fat binaries** |
| `add_version_min.c` | 66 | append `LC_VERSION_MIN_MACOSX` |

**Live-image walkers** — same structures, but `_dyld_*` + slide, in-process:

| file | what it walks |
|---|---|
| `avxemu/src/handler.c` | a loaded image's symtab (`real_sym`); indirect symbol table → pointer slots (the rebind) |
| `avxemu/src/patch_mem.c`, `tramp.c` | `__TEXT` bounds, page protections, in-place code patching |
| `mavericks-legacy-support/src/init_offsets.c` | the main image's `__TEXT,__init_offsets` |
| `mavericks-legacy-support/src/dlopen_interpose.c` | image lookup |

Plus a dozen avxemu test tools that parse the binary to find candidate
instructions.

## The duplication is not subtle

Independent implementations, counted by grep:

- **16 files** iterate load commands from `mach_header_64.ncmds`
- **10** validate `MH_MAGIC_64` themselves
- **12** carry their own ULEB128 code
- **5** compute a `__LINKEDIT` base — and the file form
  (`vmaddr - fileoff`) differs from the in-memory form (`+ slide`), which is
  exactly the kind of off-by-one-concept that produces silent corruption
- `fix_macho -change` and `change_dylib -change` are two answers to one
  question, differing in fat-binary support versus header-pad handling

Nobody shares the two hardest assets: `macho_grow.h`'s enumeration of every
file-offset field a shift must touch, and the library-ordinal model that
`patch_macho` *emits* and `change_dylib` *renumbers* — two files that must agree
about `SET_DYLIB_ORDINAL_IMM` versus `_ULEB` versus `_SPECIAL_IMM`, and
currently agree by coincidence.

## Shape

One repo, one library, one multi-call CLI. Working name `macho9` — Mach-O
surgery for hosts too old to have any: builds with stock 10.9 clang, no
dependencies, edits binaries from toolchains fifteen years newer.

```
src/
  image.c      open/validate/iterate; find segment, section, load command
  linkedit.c   symtab, strtab, indirect symbols; the offset-bump table
  uleb.c       decode / encode_fixed / minlen
  bind.c       walk, rewrite, and emit bind & rebase opcode streams
  chained.c    parse chained fixups; lower them to classic dyld info
  grow.c       header growth + every base-relative fixup it invalidates
  ordinals.c   the library-ordinal map: build, apply, validate
  live.h       header-only, malloc-free: the same queries against loaded images
cli/macho9.c   verbs
tests/         hermetic fixtures + end-to-end against a real binary
```

`live.h` is deliberately a header, not part of the library. avxemu's core must
stay VEX-free and its handler async-signal-safe; it cannot link something that
might allocate. The shared thing is the *structure knowledge*, not the code
path.

## Verbs

```
macho9 declassify IN OUT     chained fixups -> LC_DYLD_INFO_ONLY   (patch_macho)
macho9 dylib FILE -change/-delete/-add/-insert/-reexport           (change_dylib + fix_macho)
macho9 grow FILE N                                                 (macho_grow)
macho9 minos FILE 10.9                                             (add_version_min)
macho9 info FILE             dump load commands, ordinals, pads
macho9 verify FILE           check the invariants
```

`info` is worth having on its own: 10.9's otool prints
`?(0x80000034) Unknown load command` for everything modern, so today you decode
chained-fixups binaries by hand.

**`verify` is the reason to build this.** Both bugs found this week were
silent successes — every tool reported OK and the binary died in the loader:

- `-grow` left `__init_offsets` entries a page low (base-relative data not
  re-based)
- `-delete` left library ordinals stale (`dyld: library ordinal (4) too big`)

Neither is hard to *check*: ordinals within range and non-orphaned, `__LINKEDIT`
covering every appended blob, function-starts and `__init_offsets` consistent
with the image base, section offsets inside the file. A `verify` that runs in
the wrapper between the rewrite and the `mv` converts this whole class from
"binary replaced, re-download that version" into "patch refused, nothing lost".

That suggests one more verb:

```
macho9 port FILE --for 10.9 --insert @loader_path/libA.dylib ...
```

the wrapper's three-step pipeline as one atomic, verified operation.

## One repo — `mavericks-machotools`

An earlier draft of this proposed two: a source repo plus a `mavericks-*`
packaging repo pinning it. That was pattern-matching on
`mavericks-legacysupport`, and it was wrong. Legacysupport is two-layered
because its upstream is **somebody else's** — `macports/macports-legacy-support`,
tracked by Renovate on their tags. Splitting a repo you own means tagging your
own source, waiting for a bot to open a bump PR against yourself, and cutting a
second release, for nothing.

The family already has the first-party shape: `mavericks-magic-trackpad2` holds
its own `src/`, CMake against shared-cmake, tests, a characterization corpus,
the Sparkle updater, and `release.yml` — one repo, no `UPSTREAM_VERSION`,
because it *is* its own upstream. Same for `mavericks-golang`, `-tailscale`,
`-clang`, and most of the family.

So: **one repo, first-party, no `UPSTREAM_VERSION`.** Source, tests, the `.pkg`,
and the Sparkle appcast together. mavericksforever.com keeps building and
hosting `patch_macho`/`change_dylib`/`add_version_min` for `install.sh` from
that same repo, exactly as it builds them from `Mavericks-Porting-Resources`
today; ModernMavericks additionally ships a `.pkg` for people who want the tools
on their 10.9 machine.

**The repo count follows ownership, not function.** If Wowfunhappy would rather
keep the Mach-O tools under his own account — reasonable, `patch_macho` and
`fix_macho` are his — then it becomes third-party to the family and the
legacysupport two-layer shape reappears, with `UPSTREAM_VERSION` pinning his
tags. That is a governance question to settle first; the technical work is
identical either way.

The build-equivalence invariant fits unusually well here. These tools *run* on
10.9 today because they are built there; under `mavericks_build_mode` the native
and cross recipes become one, and the compat guard proves the cross-built
binaries are 10.9-safe without a 10.9 runner.

And `verify` doubles as this project's in-CI characterization proof. You cannot
launch a 10.9 binary on the runner, but you can commit a small pristine
chained-fixups fixture, run the whole pipeline over it, and assert the output's
invariants hold. That is a stronger check than most of the family can manage,
and it is the same code that guards the wrapper at runtime.

## Sequencing

**Land the three pending branches into `Mavericks-Porting-Resources` first.**
`macho-grow-init-offsets` and `change-dylib-insert-renumber` are bug fixes that
reach users through `install.sh` as soon as they merge; a reorganisation in
front of them delays a loader-crash fix for the sake of tidiness, and starts
the new repo from a knowingly-broken base.

Then, inside the new repo from day one rather than as a later split:

1. `uleb.c` + `image.c` — mechanical, deletes the most code
2. `fix_macho` and `change_dylib` converge (fat support from one, pad/grow/
   insert from the other)
3. `ordinals.c` shared, so the emitter and the renumberer agree by construction
4. `verify`, wired into the wrapper before its `mv`
5. release.yml + Sparkle, once the tools are worth cutting a .pkg for

## How this meets avxemu

`mavericks-avxemu` is the same story: first-party source, one repo, its own
`.pkg`. Two repos total, not four.

It needs `live.h` — the header-only, malloc-free subset — and the family rule is
consume-don't-vendor, so `mavericks-machotools` should install a CMake package
exporting an INTERFACE target that avxemu picks up with `find_package`, the same
way projects consume `shared-cmake`. The constraint travels with it: anything
avxemu's SIGILL handler can reach must stay allocation-free and VEX-free, so
`live.h` is a header and never grows a `.c`.

That does make one `mavericks-*` repo a build-time dependency of another, which
the family hasn't had to express before outside shared-cmake. Worth deciding
deliberately: if it turns out awkward, the fallback is for avxemu to keep its
own copy of the handful of structure walks it needs, which is what it does today
and which costs little — the walks are small; it is the *rewriters* whose
duplication actually hurts.

## Honest costs

This is churn on code that currently works and is shipped to real users. Steps
1–2 are refactors with no user-visible benefit. The case rests on `verify` and
on the emitter and renumberer agreeing about ordinals by construction — if only
part of this happens, do 3 and 4.

It is also Wowfunhappy's code in part: `patch_macho` and `fix_macho` are his;
`change_dylib -grow/-add/-insert`, the renumbering, and the `__init_offsets`
re-base are ours. Whose account the repo lives under is worth settling before
the first commit, not after.
