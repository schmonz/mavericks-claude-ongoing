# Ideas / backlog (not yet planned)

Deferred ideas for the Mavericks launcher + `libavxemu`. Distinct from the
startup-spin fix (that has its own plan); these are smaller, opportunistic.

---

## Scope the AVX shim to the one binary that needs it (stop it crashing child `node`)

**Problem.** The launcher injects `libavxemu.dylib` via `DYLD_INSERT_LIBRARIES`.
That env var is **inherited by every child process** by design. The native
Claude binary needs the shim (no AVX2 on this CPU); but children like host
`node` (e.g. clode's extractor/tests, any `node`-spawning tool) do **not** — and
the shim actively **crashes** them: `malloc: incorrect checksum for freed
object` (heap corruption). Bare `DYLD_INSERT_LIBRARIES= node --version` runs
fine, so node never needed the shim — the crash is the shim *intruding*.

**Why it crashes node (mechanism, evidenced 2026-06-29).** `libavxemu` is not a
passive trap-and-emulate shim. Inspecting the dylib:
- It has a `__mod_init_func` **constructor** that runs in *every* process that
  loads it, and does **load-time code patching**: a length-disassembler engine
  (`_lde_scan_func`, `_lde_scan_zcnt`, `_lde_cflow`) plus
  `_avxemu_install_trampolines`, `_avxemu_patch_lzcnt`, `_avxemu_build_thunk`,
  and a trampoline pool (`_avxemu_pool_*`). It scans executable code, finds
  AVX2/BMI/lzcnt/tzcnt sites, and rewrites them in place with trampolines.
- It **interposes `signal`/`sigaction`** (the `__interpose` section's two entries
  → `_avxemu_sigaction` @0x8270, `_avxemu_signal` @0x8da0) to own the SIGILL
  handler.

Tuned for the Claude/Bun binary, that scan-and-patch is fine. Forced into `node`
(different layout; V8 runs its own JIT and its own SIGILL/SIGSEGV handlers for
stack guards / Wasm traps), the patch pass + signal interposition stomp memory.

**Current workaround (option A — in place).** Empty the var for children via
Claude Code `~/.claude/settings.json`:
```json
"env": { "DYLD_INSERT_LIBRARIES": "" }
```
The parent (already launched with the shim) is unaffected; children spawn clean.
Cheap and correct *for clode* (node never needs the shim). **Downside:** it's
per-machine config that's easy to forget — a machine missing this block silently
breaks every node-spawning test. (Hit exactly this on 2026-06-29 on a second box.)

**The idea (option B — the principled fix).** Don't use the env var at all. Add
`libavxemu` as an **`LC_LOAD_DYLIB` load command baked into the native Claude
binary's Mach-O header**. Then only that binary loads the shim; nothing is in the
environment, so **no child inherits anything** — the "machine forgot the scrub"
failure class disappears by construction.
- Tooling likely already present: `change_dylib` and `patch_macho` in
  `~/.local/share/claude-mavericks/` are Mach-O load-command surgery.
- **Tradeoffs:** must re-patch on every Claude Code update (the launcher/update
  path could do this automatically); editing load commands invalidates the
  signature → ad-hoc re-sign (already being done for the other patches).

**Option C (noted, not recommended).** macOS strips `DYLD_*` across a child with
hardened runtime lacking `com.apple.security.cs.allow-dyld-environment-variables`
(or SIP-protected / setuid). Could ad-hoc-sign `node` that way — more fragile and
node-specific than B.

**Recommendation.** Keep A as the safety net; pursue **B** so the shim belongs to
the one binary that needs it instead of leaking into every child.
