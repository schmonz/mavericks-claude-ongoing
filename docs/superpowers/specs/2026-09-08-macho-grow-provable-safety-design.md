# macho_grow: prove it or refuse

**Status:** design, approved 2026-09-08. Implements against
`Mavericks-Porting-Resources` master `c4ead57`.

Make `-grow` safe and correct on the Claude Code class of binary, and make it
**refuse whenever it cannot prove the result is right**. Today it does neither
reliably: it silently corrupts several base-relative structures, and the only
thing standing between us and shipping such a binary is a guard that refuses the
whole operation.

## The problem, measured

`macho_grow` makes header room by lowering the image base: it donates bytes from
`__PAGEZERO`, drops `__TEXT.vmaddr`, and leaves every section at its original vm
address. Nothing that stores an *absolute* address has to change. Everything that
stores an **offset from the image base** must gain `grow`.

We have handled those reactively, one per incident. On Claude Code 2.1.263:

| structure | base-relative payload | today |
|---|---|---|
| `LC_FUNCTION_STARTS` leading delta | 1 value | handled |
| `__TEXT,__init_offsets` | initializer offsets | handled |
| export trie | 670 addresses (669 nonzero) | **refused** by the trie guard |
| `LC_DATA_IN_CODE` | **4838 entries, all landing in `__text`** | **blob relocated, contents untouched** |
| `__TEXT,__unwind_info` | 13 first-level + 198 LSDA entries | **not referenced anywhere in the file** |

The last two are live silent-corruption bugs. `macho_grow` bumps
`LC_DATA_IN_CODE`'s `dataoff` — the file offset where the table lives — and never
touches the offsets inside it. Same for `LC_SEGMENT_SPLIT_INFO` and
`LC_LINKER_OPTIMIZATION_HINT`, neither of which appears in this binary.

They do not surface in normal use. Data-in-code and compact unwind are consulted
during exception unwinding, crash reporting, and debugging — not at startup and
not in an idle session. The spin canary passes on a binary with all 4838 entries
wrong. **That is the failure mode this design exists to eliminate: tools that
report success on a broken result.**

### The export-trie guard was right

The guard is Wowfunhappy's, from `38cb0b8` (2026-08-28). Before it, `-grow` ran
on Claude Code and produced a launching binary with 669 export addresses a page
low. It never bit us because nothing in our setup resolves those exports; a
native `.node` addon would have. The guard is a correct defect report against our
`-grow`, and this design completes it rather than removing it.

Its stated blocker does not, however, apply here. Measured over all 670 entries,
for grows of 4K, 8K and 16K: **zero need a wider ULEB encoding**, and zero need
redundant padding — the minimal encoding of `addr + grow` is exactly the original
width in every case. A prototype rebase (scratchpad only) kept the trie
byte-identical in size, left `__LINKEDIT` untouched, and preserved 669/670
resolved vm addresses. The 670th is `__mh_execute_header`, which correctly
follows the base down.

## Why this geometry

To make room in front of the file, either the base moves down or the content
moves up. There is no third option, and each breaks a different set of things.

| | must rebase | scale on 2.1.263 |
|---|---|---|
| shift-up (LIEF, llvm-objcopy) | absolute addresses: `n_value`s, rebases, binds, relocations, chained fixups | ~94,900 rebases + 1,235 binds |
| **base-lower (ours)** | base-relative offsets only | **5 structures** |

External tools are also unavailable, not merely unattractive: 10.9's
`install_name_tool` refuses to open these binaries outright (*"file not in an
order that can be processed (dyld_info out of place)"*), LIEF needs a modern
macOS C++ runtime, and llvm-objcopy a cross-built toolchain. See
`docs/proposals/macho-toolkit.md`.

Base-lowering remains the right geometry by a wide margin. We simply never
finished the enumeration.

## Contract

After this change, `mg_grow_header` guarantees:

1. It returns 0 only if every base-relative structure it knows about has been
   rebased **and** independently re-verified.
2. It returns -1, with a specific message and the caller's buffer **byte-identical**,
   in every other case — including any load command or section it cannot classify.
3. It never returns 0 having partially transformed a buffer.

"Cannot classify" is a refusal, not a warning. Unknown means unsafe.

## Architecture

Four phases. The buffer is mutated only in phase 3.

```
mg_grow_header(pbuf, pfsize, grow_req)
  1. CLASSIFY   every load command + section
                  inert                     -> ok
                  base-relative w/ handler  -> record it
                  unknown                   -> REFUSE
  2. AUDIT      every handler at patch=0            (buffer pristine)
                  "would widen" / malformed -> REFUSE
  3. APPLY      the geometry change, then every handler at patch=1
  4. VERIFY     mg_verify() on the transformed buffer
                  mismatch -> REFUSE, restore, free the working copy
```

Phase 4 is new code. There is **no post-transform verification of any kind
today** — only pre-mutation audits, plus assertions that an apply did not fail.

### Phase 1: classification

Every load command is one of:

- **inert** — carries no base-relative payload (`LC_UUID`, `LC_LOAD_DYLIB`,
  `LC_RPATH`, `LC_SYMTAB`, `LC_DYSYMTAB`, `LC_MAIN`, …). `LC_MAIN.entryoff` is a
  file offset and is already bumped by the existing offset walk.
- **base-relative** — must have a registered handler:
  `LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`, `LC_DYLD_INFO[_ONLY]` (export trie),
  `LC_DYLD_EXPORTS_TRIE`.
- **refused outright** — `LC_DYLD_CHAINED_FIXUPS`, `LC_SEGMENT_SPLIT_INFO`,
  `LC_LINKER_OPTIMIZATION_HINT`. Each carries base-relative data we do not
  rebase. Chained fixups are already converted by `patch_macho` before
  `change_dylib` runs, so refusing costs the pipeline nothing.
- **unknown** — anything else. Refuse.

Sections are classified by type and, where the type is `S_REGULAR`, by
`(segname, sectname)`:

- **base-relative:** `S_INIT_FUNC_OFFSETS`; `__TEXT,__unwind_info`.
- **inert:** everything whose contents are absolute pointers (fixed up by rebase
  opcodes, unchanged by a base move), self-relative data, or opaque payload —
  including `__TEXT,__eh_frame`, which is pc-relative.
- **unknown section *type*:** refuse. An unrecognized *name* with a recognized
  inert type is fine; the type is what says how the contents are encoded.

### Phase 3: the five handlers

Each handler implements `locate / audit / apply / addresses`, the last returning
resolved vm addresses for phase 4.

| handler | fields to bump | notes |
|---|---|---|
| `funcstarts` | leading ULEB delta | exists |
| `init_offsets` | every entry | exists |
| `export_trie` | every **nonzero** address, re-encoded at its original ULEB width | prototyped. `__mh_execute_header` is exported at 0 and **must stay 0** — it names the header, which moved with the base |
| `data_in_code` | `offset` of all 4838 entries | new; flat `{uint32 offset; uint16 length; uint16 kind}` array |
| `unwind_info` | see below | new |

`unwind_info` is the subtle one, and the reason phase 4 exists:

| field | count (2.1.263) | action |
|---|---|---|
| first-level index `functionOffset` (incl. the trailing sentinel) | 13 | bump |
| LSDA index `functionOffset` **and** `lsdaOffset` | 198 × 2 | bump |
| regular second-level page entry `functionOffset` | 0 here; possible in general | bump |
| **compressed second-level page entries** | **11,975** | **do NOT touch** — the low 24 bits are a delta from the page's own first-level `functionOffset`, so they are invariant under a uniform bump |
| `commonEncodings`, `personalities`, page/LSDA *section* offsets | — | offsets within the section; invariant |

Bumping those 11,975 deltas would corrupt the binary in exactly the silent way
this design exists to prevent. All fields are `uint32`; the largest base-relative
value here is `0x3cbbd6c`, leaving ~4.2 GB of headroom, but every bump is still
overflow-checked.

### Phase 4: `mg_verify`

Written **once**, in `macho_grow.h`, callable on any buffer. Two independent
families of check:

- **Invariant** — for each base-relative structure, the resolved vm address
  before equals the resolved vm address after. Catches handler bugs, off-by-one,
  and double-application.

  This alone would have caught **the double-apply defect** (PR #10, see
  `docs/proposals/macho-toolkit.md`): two correct `__init_offsets` re-base
  functions, written months apart by different people against different
  predicates — section *name* versus section *type* — met in a merge and silently
  composed, so every entry gained `2*grow`. No review catches that. An invariant
  check does, without knowing the duplication exists.
- **Plausibility** — every base-relative target lands inside a mapped executable
  range, and where applicable on a known function start. This is the check that
  catches *unhandled* structures: after a grow, an un-rebased offset points a
  page low and stops being plausible. It needs no knowledge of the specific bug.

Neither sees a structure we have never heard of. That is what phase 1's refusal
is for. Three layers, three different classes of mistake.

Verify never scans the whole file: the structures are small and their offsets are
known (trie 18KB, data-in-code 38KB, unwind 51KB), so it is cheap enough to run
on every patch of a 208MB binary.

#### Call sites

One implementation, three callers — deliberately, because the double-apply defect
above was two implementations of one idea silently composing.

| site | catches | this spec |
|---|---|---|
| **(i)** inside `mg_grow_header`, post-transform | bugs in the grow itself | **yes** |
| **(iii)** wrapper gate before the `mv` | bugs in **any** tool in the pipeline | **yes** |
| (ii) `macho9 verify FILE` | standalone auditing | later, with the toolkit |

Site (iii) is the one that pays for itself. The wrapper runs `patch_macho` →
`add_version_min` → `change_dylib`, and only the last has any self-checking.
`patch_macho` rewrites ~94,900 rebases and 1,235 binds with no verification at
all. (iii) also covers a *future upstream* tool regressing, since `$MF` is
refetched on every `MF_GEN` bump — which is why the wrapper must call **our**
verify, shipped as a small `macho_verify` binary in `$MFL` beside
`change_dylib`, not upstream's.

Wrapper change (a fifth edit in `scripts/mf-wrapper-rebase.sh`): run
`$MFL/macho_verify "$T"` after the patch chain and before `mv "$T" "$REAL"`;
on nonzero exit, refuse the `mv` and keep the working binary. It composes with
the existing linked-avxemu fallback: a verify failure is just another reason the
patch did not happen.

This converts the whole defect class from *"binary replaced, re-download that
version"* into *"patch refused, nothing lost."*

## Testing

`macho_grow_test.c` already drives `mg_grow_header` end to end. Add:

1. **Synthetic fixtures** — a generated Mach-O carrying each base-relative
   structure, with known-correct expected values. One per handler.
2. **A double-apply regression** — a fixture where one structure is rebased by
   two passes; verify must catch `2*grow`. This is the PR #10 defect, pinned.
3. **Negative controls** — for each handler, disable it and assert `mg_verify`
   *fails*. A verify that cannot fail is not a verify. This is the same shape as
   avxemu's `AVXEMU_NO_REBIND=1` control, which is what proved that test bites.
4. **Classification refusals** — a fixture with an unknown load command, and one
   with `LC_LINKER_OPTIMIZATION_HINT`; both must refuse with buffer unchanged.
5. **Golden run** — opt-in via env (the binary is 208MB): grow the real Claude
   Code binary, assert every export, data-in-code entry, unwind offset and
   initializer resolves to its original vm address, then run it and the spin
   canary.

## Sequencing

1. `mg_verify` skeleton + the invariant check for the two **existing** handlers.
   Prove the harness fails when it should, before adding anything new.
2. `unwind_info` handler. **First**, because it is the one that might defeat us;
   better to learn that on day one. Now assessed tractable: ~409 values to bump
   and one large set to leave alone.
3. `data_in_code` handler — a flat array, the easy one.
4. `export_trie` handler — port the verified prototype.
5. Phase 1 classification + refusals.
6. Plausibility checks.
7. `macho_verify` CLI + the fifth wrapper edit.
8. PR to Wowfunhappy, framed as completing his guard.

Steps 1–6 land in `Mavericks-Porting-Resources`; step 7 in
`mavericks-claude-ongoing`.

## Risks

- **`unwind_info` in the general case.** We have measured one binary: 12
  compressed pages, no regular pages. The regular-page path will be written from
  the format definition and covered by a synthetic fixture, not by observation.
- **Plausibility checks producing false refusals.** "Lands on a known function
  start" is only valid where `LC_FUNCTION_STARTS` exists. Where it does not, the
  check degrades to range-only rather than refusing.
- **Divergence from upstream.** This touches a file Wowfunhappy has also edited.
  Land it as one reviewable PR, not a series.

## Non-goals

Dylibs and bundles (no `__PAGEZERO` to donate), 32-bit Mach-O, chained-fixups
inputs, and rebasing `LC_SEGMENT_SPLIT_INFO` / `LC_LINKER_OPTIMIZATION_HINT`
payloads. All are refused, explicitly, with a message naming the reason. The
`macho9 verify` CLI verb is deferred to the toolkit; `macho_verify` here is the
minimum binary the wrapper needs.
