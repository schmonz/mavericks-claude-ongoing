# Harnesses & launchers

Tools for the avxemu startup-spin investigation. Run them from the repo root
(`cwd = ../mavericks-claude-ongoing`). They are self-contained: the pyte harnesses
resolve their launcher (`claude_185`) relative to this `scripts/` dir, so there is
**no `/tmp` bootstrap**. Only runtime scratch lives in `/tmp` (`/tmp/spin.pid`,
`/tmp/cj.bak`).

See `../docs/STARTUP-HANG-OPTIONS.md` (the brief) and
`../docs/superpowers/plans/2026-06-28-avxemu-startup-spin-fix.md` (the plan) for how these are used,
and `../docs/RULED-OUT.md` for everything already eliminated.

## What each is

- **pyte_watch.py `<secs>`** — the RELIABLE measurement. Faithful pyte VT100 terminal
  (renders, answers DA/XTVERSION/OSC11), prints child CPU% every 3s via external `ps`.
  `LAUNCHER=scripts/claude_179` (or `_185`) env selects the version; default is
  `claude_185` (sibling). Trust this, not expect-based harnesses.
- **pyte_type.py** — writes the child pid to `/tmp/spin.pid`, types into the TUI to
  check responsiveness, holds the process alive ~20s for external probing (dtrace/lsof).
- **pyte_term.py `<label> ANSWER|SILENT`** — A/B whether answering terminal queries
  changes the spin (it doesn't — refuted; kept for reference).
- **profile_startup.py** — runs with `CLAUDE_CODE_PROFILE_STARTUP=1`, captures the
  headless-profiler checkpoint log. NOTE: only works headless and localizes the
  pre-existing *grove* path, not our regression (see brief "WALLS").
- **catch-spin.sh** — launch trusted 185, wait until CPU>70%, print live `PID` +
  `__TEXT` base (for dtrace). Leaves it running.
- **hot-offset.sh `PID BASE`** — dtrace-sample the user PC, print top binary offsets
  (`hotPC - BASE`). The Phase-1 / Track-C localizer.
- **claude_185 / claude_179** — Mavericks launchers (DYLD-inject `libavxemu`, patch the
  Mach-O, exec the pinned version). `sed`-derived from `/usr/local/bin/claude`
  (`/tmp/claude_fast`). `_dbg` variants append `--debug`; `_nomcp` drops `--mcp-config`.
  Host-specific (hardcode this machine's install paths).
- **fetch-version.sh `<ver>`** — download + checksum-verify a Claude Code version into
  `~/.local/share/claude/versions/<ver>` (the autoupdater reaps old ones).

## One-breath repro (185 spins, 179 idles)

```sh
cd /Users/schmonz/Documents/code/trees/mavericks-claude-ongoing
mkdir -p ~/Documents/code/trees/trusttest && echo hello > ~/Documents/code/trees/trusttest/README.md
cp ~/.claude.json /tmp/cj.bak
python3 - <<'PY'
import json,os
p=os.path.expanduser('~/.claude.json'); d=json.load(open(p))
d.setdefault("projects",{})["/Users/schmonz/Documents/code/trees/trusttest"]={"hasTrustDialogAccepted":True}
json.dump(d,open(p,"w"))
PY
cd ~/Documents/code/trees/trusttest
LAUNCHER=/Users/schmonz/Documents/code/trees/mavericks-claude-ongoing/scripts/claude_185 \
  python3 /Users/schmonz/Documents/code/trees/mavericks-claude-ongoing/scripts/pyte_watch.py 24   # pegs 100%
LAUNCHER=/Users/schmonz/Documents/code/trees/mavericks-claude-ongoing/scripts/claude_179 \
  python3 /Users/schmonz/Documents/code/trees/mavericks-claude-ongoing/scripts/pyte_watch.py 24   # idles
cp /tmp/cj.bak ~/.claude.json   # ALWAYS restore
```
