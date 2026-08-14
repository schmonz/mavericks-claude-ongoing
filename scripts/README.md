# scripts

What's left after the spin was fixed. Run from the repo root.

- **`spin_canary.sh`** — regression check for the wide-character hang class.
  Launches Claude in a throwaway `$HOME` with your real plugin payloads and
  fails if it doesn't go idle within 120s. Run it after a Claude Code, plugin,
  or `libavxemu` update. `SPIN_CANARY_LAUNCHER` overrides the launcher
  (default `/usr/local/bin/claude`), `SPIN_CANARY_PROJECT` the project dir.
- **`pyte_ttidle.py <secs>`** — the pyte VT100 harness the canary drives:
  runs the launcher on a pty, reports when the TTY goes idle. Needs `pyte`.
- **`fetch-version.sh <version>`** — download and checksum-verify an upstream
  Claude Code build into `~/.local/share/claude/versions/`.

The investigation-era tooling (lldb samplers, fault-stream dumps, hook A/B and
bisection harnesses, JSC flag sweeps, the pinned `claude_179`/`claude_185`
launchers, the defended wrapper) was deleted 2026-08-13; it's in git history.
