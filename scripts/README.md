# scripts

What's left after the spin was fixed. Run from the repo root.

- **`spin_canary.sh`** — regression check for the wide-character hang class.
  Launches Claude in a throwaway `$HOME` with your real plugin payloads and
  fails if it doesn't go idle within 120s. Run it after a Claude Code, plugin,
  or `libavxemu` update. `SPIN_CANARY_LAUNCHER` overrides the launcher
  (default `/usr/local/bin/claude`), `SPIN_CANARY_PROJECT` the project dir.
- **`pyte_ttidle.py <secs>`** — the pyte VT100 harness the canary drives:
  runs the launcher on a pty, reports when the TTY goes idle. Needs `pyte`.
- **`avxemu_probe.c`** — ask a shipped `libavxemu.dylib` whether it still has
  both correctness fixes (the `66`-prefix lzcnt decode and the VEX.128
  VPMOVMSKB upper-bits mask), by driving real instruction bytes through its
  exported `decode`/`avxemu_emulate`. Run it after **every** `install.sh`, which
  re-downloads the dylib. Build with
  `cc -I../Mavericks-Porting-Resources/avxemu/src -o /tmp/avxemu_probe scripts/avxemu_probe.c`.
- **`mf-wrapper-rebase.sh`** — fetch the wrapper that mavericksforever.com's
  `install.sh` currently emits, reapply our local edits, print the result.
  Every edit is anchored to exact upstream text and the script dies if an anchor
  has moved, so upstream drift surfaces instead of a fix silently vanishing.
  `INSTALLER=/path/to/install.sh` rebases against a local copy.
- **`mf-build-local.sh`** — build what the wrapper takes from
  `~/.local/share/claude-mavericks-local` instead of from mavericksforever.com:
  `change_dylib` and a rebind-capable `libavxemu.dylib` (for linking avxemu),
  and `libSystemWrapper.dylib` from git ref `$SYSWRAP_REF` (default
  `kevent64-receipt-not-stash`, whose kevent64 shim stops replaying events for
  closed-and-reused fds, the intermittent launch crash). Run it after every
  `install.sh`, then `mf-wrapper-rebase.sh`. `SYSWRAP_REF=` (empty) drops the
  local libSystemWrapper; the wrapper re-patches back to the shipped one on the
  next launch.
- **`claude-binary-snapshot.sh`** — hard-links every distinct Claude Code
  binary (pristine download and patched result) into
  `~/.local/share/claude-binary-snapshots`, with a manifest of size and sha256,
  so a build that crashed can still be diffed after the updater replaces it.
  Runs every 60s from the launchd agent `com.schmonz.claude-binary-snapshot.plist`
  (install steps in the script's header). Tested by
  `claude-binary-snapshot-test.sh`.
- **`fetch-version.sh <version>`** — download and checksum-verify an upstream
  Claude Code build into `~/.local/share/claude/versions/`.

The investigation-era tooling (lldb samplers, fault-stream dumps, hook A/B and
bisection harnesses, JSC flag sweeps, the pinned `claude_179`/`claude_185`
launchers, the defended wrapper) was deleted 2026-08-13; it's in git history.
