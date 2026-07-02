#!/bin/sh
# Which JSC subsystem owns the non-Latin1 spin? Sweep JSC_* options against the
# standing repro (throwaway HOME, poisoned superpowers hook). A flag whose arm
# idles names the guilty subsystem AND is a candidate launcher-level kill-switch.
# Metric: pyte_ttidle 150s (healthy = 9s).
set -e
MC=/Users/schmonz/Documents/code/trees/mavericks-claude-ongoing
D=/Users/schmonz/Documents/code/trees/trusttest

run_one() {  # $1 = label, $2 = env assignment (may be empty)
  cd "$D"
  R=$(env $2 HOME=/tmp/spin_home LAUNCHER="$MC/scripts/claude_185_natslice" \
      python3 "$MC/scripts/pyte_ttidle.py" 150 2>&1 | tail -2 | tr '\n' ' ')
  echo "ARM=$1  $R"
}

run_one CTRL ""
run_one noConcurrentJIT "JSC_useConcurrentJIT=false"
run_one noRegExpJIT     "JSC_useRegExpJIT=false"
run_one noDFG           "JSC_useDFGJIT=false"
run_one noFTL           "JSC_useFTLJIT=false"
run_one noConcurrentGC  "JSC_useConcurrentGC=false"
run_one noJIT           "JSC_useJIT=false"
echo "SWEEP DONE"
