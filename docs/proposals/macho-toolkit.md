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

## Migration

Extract inside `Mavericks-Porting-Resources` first, split later. The tools ship
to users as prebuilt binaries via `install.sh`, so distribution doesn't care
where the source lives, and a premature split just adds a vendoring step to
somebody's build.

1. `uleb.c` + `image.c` — mechanical, no behaviour change, deletes the most code
2. `fix_macho` and `change_dylib` converge on one implementation (fat support
   from one, pad/grow/insert from the other)
3. `ordinals.c` shared, so the emitter and the renumberer agree by construction
4. `verify` + wire it into the wrapper before `mv`
5. split out, once the API has stopped moving

## Honest costs

This is churn on code that currently works and is shipped to real users. The
tools are small, and small tools that work are cheap to leave alone — the case
rests almost entirely on `verify` and on the emitter/renumberer agreeing about
ordinals, not on the tidiness. Steps 1–2 are refactors with no user-visible
benefit; if only part of this ever happens, do 3 and 4.

It is also Wowfunhappy's code and his call. `patch_macho` and `fix_macho` are
his; `change_dylib -grow/-add/-insert`, the renumbering, and the
`__init_offsets` re-base are ours.
