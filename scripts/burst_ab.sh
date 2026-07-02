#!/bin/sh
# One burst run under the ISOLATED throwaway HOME (never touches ~/.claude.json),
# with the natslice test dylib. Polls the child's CPU-TIME until it exits, prints
# the total CPU seconds consumed + OPHIST total. Kills ONLY the exact /tmp/spin.pid
# (never a version-grep-kill; the user's live 179 must be untouched).
#   usage: burst_ab.sh <AVXEMU_NATIVE 0|1> <label>
set -u
NATIVE="$1"; LABEL="${2:-run}"
SCR=/Users/schmonz/Documents/code/trees/mavericks-claude-ongoing/scripts
D=/Users/schmonz/Documents/code/trees/trusttest
DYL=/tmp/avxemu_natslice/libavxemu.dylib
rm -f /tmp/spin.pid /tmp/ophist.out
( cd "$D" && HOME=/tmp/spin_home AVXEMU_OPHIST=1 AVXEMU_NATIVE="$NATIVE" \
    AVXEMU_TEST_DYLIB="$DYL" LAUNCHER="$SCR/claude_185_natslice" HOLD_SECS=200 \
    python3 "$SCR/pyte_hold.py" >/tmp/burst_${LABEL}.out 2>&1 & )

# wait for pid
i=0; while [ ! -s /tmp/spin.pid ]; do i=$((i+1)); [ $i -gt 30 ] && { echo "no pid"; exit 1; }; sleep 1; done
PID=$(cat /tmp/spin.pid)

# cputime in seconds from ps (mm:ss.dd or hh:mm:ss)
cputime() {
  t=$(ps -o cputime= -p "$1" 2>/dev/null | tr -d ' ') || return 1
  [ -z "$t" ] && return 1
  echo "$t" | awk -F: '{n=NF; s=0; for(i=1;i<=n;i++) s=s*60+$i; print s}'
}

# poll until the process exits; record last cputime + wall
start=$(date +%s); last=0
while kill -0 "$PID" 2>/dev/null; do
  c=$(cputime "$PID") && last="$c"
  sleep 0.5
done
end=$(date +%s)
oph=$(grep TOTAL /tmp/ophist.out 2>/dev/null | awk '{print $2}')
echo "NATIVE=$NATIVE $LABEL: cputime=${last}s wall=$((end-start))s ophist_total=${oph:-0} pid=$PID"
