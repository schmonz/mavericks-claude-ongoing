#!/bin/sh
# A/B: does disabling the superpowers plugin (whose SessionStart hook output is
# the string the phase-A loop grinds on) kill the sustained spin?
# Toggles enabledPlugins ONLY in the throwaway /tmp/spin_home; interleaved arms;
# metric = pyte_ttidle 300s (none = spin; <60s = no spin). Exact-PID safety is
# inside pyte_ttidle (kills only its own child).
set -e
MC=/Users/schmonz/Documents/code/trees/mavericks-claude-ongoing
D=/Users/schmonz/Documents/code/trees/trusttest
S=/tmp/spin_home/.claude/settings.json

set_plugin() {  # $1 = true|false
  python3 - "$S" "$1" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("enabledPlugins", {})["superpowers@superpowers-marketplace"] = (sys.argv[2] == "true")
json.dump(d, open(p, "w"), indent=2)
PY
}

run_one() {  # $1 = label
  cd "$D"
  R=$(HOME=/tmp/spin_home LAUNCHER="$MC/scripts/claude_185_natslice" \
      python3 "$MC/scripts/pyte_ttidle.py" 300 2>&1 | tail -2 | tr '\n' ' ')
  echo "ARM=$1  $R"
}

for arm in OFF ON OFF ON OFF; do
  if [ "$arm" = OFF ]; then set_plugin false; else set_plugin true; fi
  run_one "$arm"
done
set_plugin true   # leave the throwaway HOME in its original (control) state
echo "AB DONE"
