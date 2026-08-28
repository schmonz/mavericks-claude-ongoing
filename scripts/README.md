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
  `install.sh` currently emits, reapply our three local edits, print the result.
  Every edit is anchored to exact upstream text and the script dies if an anchor
  has moved, so upstream drift surfaces instead of a fix silently vanishing.
  `INSTALLER=/path/to/install.sh` rebases against a local copy.
- **`fetch-version.sh <version>`** — download and checksum-verify an upstream
  Claude Code build into `~/.local/share/claude/versions/`.

The investigation-era tooling (lldb samplers, fault-stream dumps, hook A/B and
bisection harnesses, JSC flag sweeps, the pinned `claude_179`/`claude_185`
launchers, the defended wrapper) was deleted 2026-08-13; it's in git history.
