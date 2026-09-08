#!/bin/sh
# Spin canary: after ANY claude/plugin/avxemu update, verify the wide-character
# hang class is still dead. Launches claude in a throwaway HOME with the current
# real plugin payloads -- em-dashes and all, which is the whole point now that
# the emulator is fixed and nothing sanitizes them -- and expects it to go idle.
# Exits 0 iff it idles within the harness timeout.
# Uses the pyte TTIDLE harness; kills only its own children.
set -e
MC=$(cd "$(dirname "$0")/.." && pwd)
D=${SPIN_CANARY_PROJECT:-/Users/schmonz/Documents/code/trees/trusttest}
CH=/tmp/spin_canary_home

rm -rf "$CH"; mkdir -p "$CH/.local/share" "$CH/.local/bin" "$CH/.claude"
ln -sf "$HOME/.local/share/claude" "$CH/.local/share/claude"
ln -sf "$HOME/.local/share/claude-mavericks" "$CH/.local/share/claude-mavericks"
# The wrapper derives $MFL from $HOME too, and when avxemu is LINKED the binary
# carries @loader_path/../A.dylib -- so without this the canary's claude refuses
# to start (correctly) rather than idling, and reads as a spin that isn't one.
ln -sf "$HOME/.local/share/claude-mavericks-local" "$CH/.local/share/claude-mavericks-local"
# NOT a symlink to $HOME/.local/bin/claude. Claude Code, running under HOME=$CH,
# installs its own launcher by WRITING to $CH/.local/bin/claude -- and a write
# through a symlink lands on the target, so that spelling silently replaced the
# real ~/.local/bin/claude with a 208MB regular file on every canary run.
# Point at the versioned binary instead: if it gets clobbered the wrapper simply
# re-patches it on the next launch, whereas a clobbered launcher symlink makes
# the wrapper patch $HOME/.local/bin/claude in place and quietly diverge from
# versions/.
REALBIN=$(readlink "$HOME/.local/bin/claude" 2>/dev/null || echo "$HOME/.local/bin/claude")
case "$REALBIN" in /*) ;; *) REALBIN="$HOME/.local/bin/$REALBIN" ;; esac
ln -sf "$REALBIN" "$CH/.local/bin/claude"

# And check afterwards regardless: this is a test harness, and a test harness
# that damages the thing it measures is worse than no harness.
WAS_LINK=$([ -L "$HOME/.local/bin/claude" ] && echo yes || echo no)
restore_launcher() {
    if [ "$WAS_LINK" = yes ] && [ ! -L "$HOME/.local/bin/claude" ]; then
        echo "CANARY: ~/.local/bin/claude was replaced during the run; restoring the symlink" >&2
        rm -f "$HOME/.local/bin/claude"
        ln -s "$REALBIN" "$HOME/.local/bin/claude"
    fi
}
trap restore_launcher EXIT INT TERM
# real plugin cache + settings, so the canary tests what you actually run
cp -R "$HOME/.claude/plugins" "$CH/.claude/plugins" 2>/dev/null || true
[ -f "$HOME/.claude/settings.json" ] && cp "$HOME/.claude/settings.json" "$CH/.claude/settings.json"
python3 - "$D" > "$CH/.claude.json" <<'PY'
import json, sys
print(json.dumps({"projects": {sys.argv[1]: {"hasTrustDialogAccepted": True,
      "projectOnboardingSeenCount": 9}}, "hasCompletedOnboarding": True}))
PY

cd "$D"
R=$(HOME="$CH" LAUNCHER="${SPIN_CANARY_LAUNCHER:-/usr/local/bin/claude}" \
    python3 "$MC/scripts/pyte_ttidle.py" 120 2>&1 | tail -2 | tr '\n' ' ')
echo "CANARY(A real payloads): $R"
case "$R" in
  *TTIDLE=none*) echo "CANARY FAILED: the spin is back."; exit 1 ;;
  *TTIDLE=*)     echo "CANARY OK: idles." ;;
  *)             echo "CANARY INCONCLUSIVE: $R"; exit 2 ;;
esac
