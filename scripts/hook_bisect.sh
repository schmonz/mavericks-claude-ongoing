#!/bin/sh
# Bisect WHAT about the superpowers session-start payload triggers the spin.
# Plugin stays ENABLED in every arm; only the hook script (in the THROWAWAY
# /tmp/spin_home plugin cache) is swapped. Arms are given as args:
#   CTRL  = original hook (full skill content)          -> expect peg
#   STUB  = tiny fixed additionalContext                -> hook-payload test
#   HALF  = first half of SKILL.md                      -> size bisection
#   FILL  = size-matched benign filler lines            -> size-vs-content
# Metric: pyte_ttidle 300s. Original hook restored at exit.
set -e
MC=/Users/schmonz/Documents/code/trees/mavericks-claude-ongoing
D=/Users/schmonz/Documents/code/trees/trusttest
C=/tmp/spin_home/.claude/plugins/cache/superpowers-marketplace/superpowers/6.1.0
H="$C/hooks/session-start"
ORIG="$C/hooks/session-start.orig"
[ -f "$ORIG" ] || cp "$H" "$ORIG"
trap 'cp "$ORIG" "$H"' EXIT INT TERM

SKILL="$C/skills/using-superpowers/SKILL.md"
PAYLOAD=/tmp/bisect_payload.md

use_payload_file() {  # hook variant that reads $PAYLOAD instead of SKILL.md
  sed 's|cat "${PLUGIN_ROOT}/skills/using-superpowers/SKILL.md"|cat /tmp/bisect_payload.md|' "$ORIG" > "$H"
}

set_arm() {
  case "$1" in
  CTRL) cp "$ORIG" "$H" ;;
  STUB) cat > "$H" <<'EOF'
#!/usr/bin/env bash
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "superpowers bisect stub"\n  }\n}\n'
exit 0
EOF
  ;;
  HALF)   head -c 1530 "$SKILL" > "$PAYLOAD"; use_payload_file ;;
  FILL)   awk 'BEGIN{for(i=0;i<70;i++)print "filler line about nothing much here at all"}' > "$PAYLOAD"; use_payload_file ;;
  FILL16) awk 'BEGIN{for(i=0;i<70;i++)print "filler line about nothing much here at all"}' > "$PAYLOAD"
          printf 'one em\342\200\224dash line\n' >> "$PAYLOAD"; use_payload_file ;;
  P*)     N=${1#P};  head -c "$N" "$SKILL" > "$PAYLOAD"; use_payload_file ;;
  T*)     N=${1#T};  tail -c +"$((N+1))" "$SKILL" > "$PAYLOAD"; use_payload_file ;;
  ASCIIFY) python3 -c '
import sys
d = open(sys.argv[1], encoding="utf-8").read()
d = d.replace("—","--").replace("→","->").replace("≠","!=")
d = d.encode("ascii","replace").decode()
open("/tmp/bisect_payload.md","w").write(d)' "$SKILL"; use_payload_file ;;
  esac
  chmod +x "$H"
}

for arm in "$@"; do
  set_arm "$arm"
  cd "$D"
  R=$(HOME=/tmp/spin_home LAUNCHER="$MC/scripts/claude_185_natslice" \
      python3 "$MC/scripts/pyte_ttidle.py" 300 2>&1 | tail -2 | tr '\n' ' ')
  echo "ARM=$arm  $R"
done
echo "BISECT DONE"
