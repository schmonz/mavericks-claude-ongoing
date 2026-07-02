#!/bin/sh
# Bimodality-robust A/B metric for the sustained spin: CPU-TIME to reach a fixed
# count of a STILL-EMULATED op (shlx, counted via OPHIST in BOTH conditions since
# only mulx/lzcnt are natively lowered). Lower cputime-to-target = faster loop.
# Isolated throwaway HOME; kills ONLY the exact /tmp/spin.pid (never a version-grep).
#   usage: rate_ab.sh <AVXEMU_NATIVE 0|1> <label> [target_shlx]
set -u
NATIVE="$1"; LABEL="${2:-run}"; TARGET="${3:-1500000}"
SCR=/Users/schmonz/Documents/code/trees/mavericks-claude-ongoing/scripts
D=/Users/schmonz/Documents/code/trees/trusttest
DYL=/tmp/avxemu_natslice/libavxemu.dylib
rm -f /tmp/spin.pid /tmp/ophist.out
( cd "$D" && HOME=/tmp/spin_home AVXEMU_OPHIST=1 AVXEMU_NATIVE="$NATIVE" \
    AVXEMU_TEST_DYLIB="$DYL" LAUNCHER="$SCR/claude_185_natslice" HOLD_SECS=300 \
    python3 "$SCR/pyte_hold.py" >/tmp/rate_${LABEL}.out 2>&1 & )
i=0; while [ ! -s /tmp/spin.pid ]; do i=$((i+1)); [ $i -gt 30 ] && { echo "no pid"; exit 1; }; sleep 1; done
PID=$(cat /tmp/spin.pid)
cputime() { t=$(ps -o cputime= -p "$1" 2>/dev/null | tr -d ' '); [ -z "$t" ] && return 1
  echo "$t" | awk -F: '{n=NF;s=0;for(i=1;i<=n;i++)s=s*60+$i;print s}'; }
shlx_ct() { grep '^shlx' /tmp/ophist.out 2>/dev/null | awk '{print $2}'; }
ct="" ; reached=""
while kill -0 "$PID" 2>/dev/null; do
  s=$(shlx_ct); s=${s:-0}
  if [ "$s" -ge "$TARGET" ] 2>/dev/null; then ct=$(cputime "$PID"); reached=1; break; fi
  sleep 0.3
done
if [ -z "$reached" ]; then
  echo "NATIVE=$NATIVE $LABEL: target $TARGET NOT reached (process exited; shlx=$(shlx_ct) cputime=$(cputime "$PID" 2>/dev/null)) pid=$PID"
else
  kill -9 "$PID" 2>/dev/null
  echo "NATIVE=$NATIVE $LABEL: cputime_to_${TARGET}_shlx=${ct}s (shlx=$(shlx_ct)) pid=$PID KILLED-exact"
fi
