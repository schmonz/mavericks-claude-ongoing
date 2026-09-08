# Converting a patched Claude Code to link avxemu instead of inserting it

How to take a Claude Code binary that Mavericks Forever has already patched and
make it load `libavxemu.dylib` as an ordinary `LC_LOAD_DYLIB` dependency, with
**no `DYLD_INSERT_LIBRARIES` anywhere**.

Done and running here since 2026-09-08 on 2.1.263. The background and the
"should we?" argument are in [linkage-poc/README.md](linkage-poc/README.md) and
[upstream/mf-installer-link-avxemu/REPORT.md](upstream/mf-installer-link-avxemu/REPORT.md);
this file is the procedure.

## Why bother

`DYLD_INSERT_LIBRARIES` is inherited by every child process, so it has to be
scrubbed back off — and a scrubbed child that re-execs the claude binary then
runs *unemulated*. That is the failure that actually bit us (embedded bfs,
SIGILL 132), not a hypothetical. Linked in, avxemu covers exactly one binary,
cannot leak, survives env scrubbing, and also covers anyone running
`~/.local/bin/claude` directly instead of the wrapper.

Cost: a patch step on every Claude Code update (the wrapper already patches),
and a hard dyld failure instead of a soft one if the dylib goes missing.

## Two things upstream does not ship yet

Checked 2026-09-08: the CDN's `libavxemu.dylib` and `change_dylib` are
byte-identical to the installed ones (`d1dba14a…`, `66acd393…`), and neither has
what this needs. Both fixes are merged in `Mavericks-Porting-Resources` master
(`c4ead57`); upstream simply has not rebuilt. **Check the artifact, not the repo.**

| needed | why | shipped? |
|---|---|---|
| `change_dylib -insert` | `-add` appends, and an appended dependency initialises *after* the ones already there. The emulator must be armed first, so it has to be ordinal 1. | no |
| avxemu's sigaction/signal rebind | 10.9's dyld honours `__DATA,__interpose` **only for inserted images**. Linked, avxemu's interposes are ignored, the app's `SIGILL` handler wins, and emulation dies at the first faulting instruction. | no |

The second one is the dangerous one: a linked non-rebind avxemu does not
degrade, it **hangs** (`--version` never returns, killed at 90s, 3/3).

## The procedure

```sh
sh scripts/mf-build-local.sh                       # build the two artifacts
sh scripts/mf-wrapper-rebase.sh > /tmp/claude-wrapper
diff /usr/local/bin/claude /tmp/claude-wrapper     # read it
sudo install -m 755 /tmp/claude-wrapper /usr/local/bin/claude
claude --version                                   # patches once, then links
```

`mf-build-local.sh` builds `libavxemu.dylib` and `change_dylib` from
`../Mavericks-Porting-Resources` into `~/.local/share/claude-mavericks-local`
(`$MFL`), runs every test that can run on this CPU, and writes a `.ok` stamp
holding the source commit — **last**, so a build that dies halfway leaves the
directory unstamped and the wrapper keeps inserting.

`$MFL` is deliberately **outside** `$MF`. `$MF` is wiped and refetched whenever
the wrapper's `MF_GEN` stops matching `$MF/.generation`; a local build placed
there would be silently replaced by the one that hangs.

The build skips `build.sh` steps 3, 4 and 6b — differential oracles that need
real AVX2 for ground truth. Those were silicon-checked on the AVX2 box for this
same tree. What it *does* run is the part that box cannot: step 8 (inserted
selftest, 11/11) and step 8i (**linked** rebind, plus the `AVXEMU_NO_REBIND=1`
negative control that proves the test can detect the rebind's absence).

## How the wrapper decides

Edit 4 in `scripts/mf-wrapper-rebase.sh`. It links only when `$MFL/.ok`,
`$MFL/libavxemu.dylib` and `$MFL/change_dylib` are all present; otherwise it
exports `DYLD_INSERT_LIBRARIES` exactly as before. Three further points:

- **The `A.dylib` alias is made whenever `$MFL/libavxemu.dylib` exists**, not
  only when linking is enabled — a binary already carrying
  `@loader_path/../A.dylib` will not launch without it. If the binary carries
  one and the local build is gone, the wrapper says so and exits instead of
  letting dyld fail cryptically.
- **The patch probe has two conditions**: no `S.dylib`, *or* linking is on and
  there is no `A.dylib`. Re-running the whole chain on an already-patched binary
  is safe — `patch_macho` and `add_version_min` detect their own work and pass
  through, and a `-change` whose old path is already rewritten is a no-op. All
  three verified 2026-09-08.
- **If the insert fails, it falls back to inserting** rather than exiting. See
  the header-room section: this is the failure that will eventually happen, and
  it must not lock you out of Claude.

## Header room — the real constraint

The load command costs 48 bytes and there is no growing your way out of it.

On 2.1.263, already patched: 96 bytes of pad (LC end 2784, first section 2880),
48 consumed by `@loader_path/../A.dylib`, **48 left**. That room exists because
the wrapper spends `-strip-lc uuid -strip-lc codesig` (40 bytes) and because the
`@loader_path/../X.dylib` names are chosen to be no longer than the `/usr/lib/…`
names they replace. It was engineered, not lucky.

**`-grow` cannot rescue this binary.** Forcing it:

```
macho_grow: export trie exports a nonzero address; its addresses are offsets
from the image base and would need a ULEB re-encode that can resize __LINKEDIT,
which is not implemented.
ERROR: new LCs (2944 bytes) don't fit and header could not be grown
```

Note *which* refusal that is: not `__init_offsets` (our `macho-grow-init-offsets`
fix handles that one), but the **export trie**, which is still unimplemented.
So the margin is the whole safety story, and a future Claude build with more
dylibs or tighter padding will fail the insert — hence the fallback.

## Verifying

```sh
otool -L ~/.local/share/claude/versions/<ver> | head -3   # A.dylib, ordinal 1
sh -c 'unset DYLD_INSERT_LIBRARIES; claude --version'     # no DYLD_* at all
sh scripts/spin_canary.sh                                 # TTIDLE=9, ~4s CPU
```

The control that actually proves linkage — move the alias aside and dyld must
refuse to launch:

```
$ mv ~/.local/share/claude/A.dylib{,.off}; claude --version
dyld: Library not loaded: @loader_path/../A.dylib
```

If that still runs, something is inserting avxemu and you are not testing what
you think you are.

## Backing out

```sh
rm ~/.local/share/claude-mavericks-local/.ok
sudo install -m 755 <the wrapper from before> /usr/local/bin/claude
```

Removing the stamp alone is *not* enough while the binary still carries
`A.dylib` — the wrapper will stop and tell you so. Either keep `$MFL` in place,
or restore the binary (re-patching from a fresh download also works, since a
freshly-downloaded binary has no `A.dylib`).

## Still to keep in mind

`USE_BUILTIN_RIPGREP=0` matters *more* now, not less. Linked, avxemu also rides
into re-execs of the binary as its embedded `rg`, which is multithreaded and
SIGBUSes against avxemu's live code patching. `ugrep` and `bfs` are clean.

Anything that runs claude under a different `$HOME` must also make `$MFL`
reachable — the wrapper derives it from `$HOME`, exactly as it does `$MF`.
`spin_canary.sh` symlinks it for this reason.
