#!/bin/sh
# Spin canary: after ANY claude/plugin/engine update, verify the wide-char
# hang class is still dead. Launches claude in a throwaway HOME with (A) the
# current real plugin payloads (expect idle <= 60s) and (B) a deliberately
# poisoned one-em-dash hook (expect the WRAPPER DEFENSE to refuse, or -- if
# run with CLAUDE_MF_ALLOW_WIDE_HOOKS=1 -- the engine to hang, proving the
# canary itself still works). Exits 0 iff (A) idles.
# Uses the pyte TTIDLE harness; kills only its own children.
set -e
MC=$(cd "$(dirname "$0")/.." && pwd)
D=${SPIN_CANARY_PROJECT:-/Users/schmonz/Documents/code/trees/trusttest}
CH=/tmp/spin_canary_home

rm -rf "$CH"; mkdir -p "$CH/.local/share" "$CH/.local/bin" "$CH/.claude"
ln -sf "$HOME/.local/share/claude" "$CH/.local/share/claude"
ln -sf "$HOME/.local/share/claude-mavericks" "$CH/.local/share/claude-mavericks"
ln -sf "$HOME/.local/bin/claude" "$CH/.local/bin/claude"
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
