#!/bin/sh
# hot-offset.sh PID BASE — dtrace-sample the user PC of a spinning pid, print the
# top binary offsets (hotPC - BASE). sudo works non-interactively on this host.
# Usage: eval "$(sh catch-spin.sh | tail -1)"; sh hot-offset.sh "$PID" "$TEXT_BASE"
set -u
PID="$1"; BASE="$2"
sudo -n dtrace -q -n "profile-1999 /pid==$PID/ { @[arg1]=count(); } tick-3s { exit(0); }" 2>/dev/null \
| awk 'NF==2{print}' | sort -k2 -n | tail -10 \
| while read PC CNT; do
    OFF=$(python3 -c "print(hex($PC-$BASE))" 2>/dev/null)
    echo "off=$OFF count=$CNT pc=$(printf '0x%x' "$PC")"
  done
