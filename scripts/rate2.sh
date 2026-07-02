#!/bin/sh
# A/B metric for the register-resident tier: CPU-time to reach TARGET of a
# still-C-emulated VECTOR op (counted via OPHIST in BOTH conditions since only
# the BMI tier is minspilled and AVXEMU_NATIVE=0 keeps vector ops in C).
# Toggle AVXEMU_MINSPILL (0=baseline full-spill BMI, 1=register-resident BMI).
# Isolated throwaway HOME; kills ONLY the exact /tmp/spin.pid.
#   usage: rate2.sh <AVXEMU_MINSPILL 0|1> <label> [target] [op]
set -u
MINSPILL="$1"; LABEL="${2:-run}"; TARGET="${3:-100000}"; OP="${4:-vpbroadcastq}"
SCR=/Users/schmonz/Documents/code/trees/mavericks-claude-ongoing/scripts
D=/Users/schmonz/Documents/code/trees/trusttest
DYL=/tmp/avxemu_natslice/libavxemu.dylib
rm -f /tmp/spin.pid /tmp/ophist.out
( cd "$D" && HOME=/tmp/spin_home AVXEMU_OPHIST=1 AVXEMU_NATIVE=0 AVXEMU_MINSPILL="$MINSPILL" \
    AVXEMU_TEST_DYLIB="$DYL" LAUNCHER="$SCR/claude_185_natslice" HOLD_SECS=300 \
    python3 "$SCR/pyte_hold.py" >/tmp/rate2_${LABEL}.out 2>&1 & )
i=0; while [ ! -s /tmp/spin.pid ]; do i=$((i+1)); [ $i -gt 30 ] && { echo "no pid"; exit 1; }; sleep 1; done
PID=$(cat /tmp/spin.pid)
cputime() { t=$(ps -o cputime= -p "$1" 2>/dev/null | tr -d ' '); [ -z "$t" ] && return 1
  echo "$t" | awk -F: '{n=NF;s=0;for(i=1;i<=n;i++)s=s*60+$i;print s}'; }
opct() { grep "^${OP}[^a-z]" /tmp/ophist.out 2>/dev/null | awk '{print $2}' | head -1; }
ct=""; reached=""
while kill -0 "$PID" 2>/dev/null; do
  c=$(opct); c=${c:-0}
  if [ "$c" -ge "$TARGET" ] 2>/dev/null; then ct=$(cputime "$PID"); reached=1; break; fi
  sleep 0.3
done
if [ -z "$reached" ]; then
  echo "MINSPILL=$MINSPILL $LABEL: target $TARGET $OP NOT reached (exited; $OP=$(opct) cputime=$(cputime "$PID" 2>/dev/null) ophistTOTAL=$(grep TOTAL /tmp/ophist.out|awk '{print $2}')) pid=$PID"
else
  kill -9 "$PID" 2>/dev/null
  echo "MINSPILL=$MINSPILL $LABEL: cputime_to_${TARGET}_${OP}=${ct}s ($OP=$(opct)) pid=$PID KILLED-exact"
fi
