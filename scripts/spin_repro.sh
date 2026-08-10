#!/bin/sh
# spin_repro.sh <version> <wide|ascii>
#
# Faithful, PLUGIN-FREE reproduction of the no-AVX2 startup spin, straight from
# the bug report: a user-settings SessionStart hook that `cat`s a crafted ~3KB /
# ~75-line additionalContext payload containing exactly one char > U+00FF (wide)
# or its all-ASCII twin (ascii). Throwaway HOME; the version binary is pinned via
# a private symlink so the live ~/.local/bin/claude is untouched. Defense is
# turned OFF (CLAUDE_MF_ALLOW_WIDE_HOOKS=1) so we measure the ENGINE, not the
# launcher. Prints the pyte TTIDLE line: TTIDLE=none == spun; TTIDLE=<n> == idled.
set -e
VER=${1:?usage: spin_repro.sh <version> <wide|ascii>}
KIND=${2:-wide}
MC=$(cd "$(dirname "$0")/.." && pwd)
WRAP="$MC/scripts/claude-wrapper-defended"
MF=$HOME/.local/share/claude-mavericks
VBIN="$HOME/.local/share/claude/versions/$VER"
PAYLOAD="$MC/docs/evidence/2026-07-02-recurrence/payload_pretty_$KIND.json"
PROJECT=${TRY_PROJECT:-/Users/schmonz/Documents/code/trees/trusttest}
CH=/tmp/spin_repro_home
[ -x "$VBIN" ]    || { echo "no such version binary: $VBIN" >&2; exit 1; }
[ -f "$PAYLOAD" ] || { echo "no such payload: $PAYLOAD" >&2; exit 1; }
[ -d "$PROJECT" ] || { echo "no trusted test project: $PROJECT" >&2; exit 1; }

rm -rf "$CH"; mkdir -p "$CH/.local/share" "$CH/.local/bin" "$CH/.claude"
ln -sf "$HOME/.local/share/claude" "$CH/.local/share/claude"
ln -sf "$MF"                       "$CH/.local/share/claude-mavericks"
ln -sf "$VBIN"                     "$CH/.local/bin/claude"
cat > "$CH/.claude/settings.json" <<EOF
{ "hooks": { "SessionStart": [ { "matcher": "startup|clear|compact",
  "hooks": [ { "type": "command", "command": "cat '$PAYLOAD'" } ] } ] } }
EOF
python3 - "$PROJECT" > "$CH/.claude.json" <<'PY'
import json, sys
print(json.dumps({"projects": {sys.argv[1]: {"hasTrustDialogAccepted": True,
      "projectOnboardingSeenCount": 9}}, "hasCompletedOnboarding": True}))
PY

cd "$PROJECT"
R=$(HOME="$CH" CLAUDE_MF_ALLOW_WIDE_HOOKS=1 LAUNCHER="$WRAP" \
    python3 "$MC/scripts/pyte_ttidle.py" "${TTIDLE_MAX:-90}" 2>&1 | tail -1)
echo "$VER/$KIND: $R"
case "$R" in
  *TTIDLE=none*) echo ">>> SPUN (engine hangs on this payload)";;
  *TTIDLE=*)     echo ">>> idled";;
  *)             echo ">>> inconclusive";;
esac
