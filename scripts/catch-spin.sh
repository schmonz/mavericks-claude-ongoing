#!/bin/sh
# catch-spin.sh — launch trusted 2.1.185, wait until it is confirmed spinning
# (CPU>70%), then print the live pid and the binary __TEXT load base. Leaves the
# process running (kill it yourself: pkill -9 -f versions/2.1.185).
# Restores ~/.claude.json on the way through. Paths resolve to this scripts/ dir.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
D=/Users/schmonz/Documents/code/trees/trusttest
mkdir -p "$D"; [ -f "$D/README.md" ] || echo hello > "$D/README.md"
cp ~/.claude.json /tmp/cj.bak
python3 - "$D" <<'PY'
import json,os,sys
p=os.path.expanduser('~/.claude.json'); d=json.load(open(p))
d.setdefault("projects",{})[sys.argv[1]]={"hasTrustDialogAccepted":True}
json.dump(d,open(p,"w"))
PY
( cd "$D" && rm -f /tmp/spin.pid && LAUNCHER="$HERE/claude_185" python3 "$HERE/pyte_type.py" >/tmp/ptype.out 2>&1 & )
PID=""; CPU=""; i=0
while [ $i -lt 25 ]; do
  sleep 2; i=$((i+1))
  PID=$(cat /tmp/spin.pid 2>/dev/null) || PID=""
  [ -n "$PID" ] || continue
  CPU=$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ')
  case "$CPU" in ''|*[!0-9.]*) continue;; esac
  if [ "${CPU%.*}" -ge 70 ]; then break; fi
done
cp /tmp/cj.bak ~/.claude.json
BASE=$(vmmap "$PID" 2>/dev/null | awk '/__TEXT/ && /2\.1\.185/{print $2; exit}')
echo "PID=$PID CPU=$CPU TEXT_BASE=$BASE"
