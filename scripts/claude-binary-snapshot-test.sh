#!/bin/sh
# Tests for claude-binary-snapshot.sh, against a throwaway HOME.
#
#   sh scripts/claude-binary-snapshot-test.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d -t snaptest)
trap 'rm -rf "$T"' EXIT INT TERM
V=$T/.local/share/claude/versions
M=$T/.local/share/claude-binary-snapshots/manifest.tsv
mkdir -p "$V"
fails=0
check() { if eval "$2"; then echo "  ok   : $1"; else echo "  FAIL : $1"; fails=$((fails + 1)); fi; }
snap() { HOME=$T sh "$HERE/claude-binary-snapshot.sh"; }
rows() { tail -n +2 "$M" | awk -F'\t' -v v="$1" '$2 == v' | wc -l | tr -d ' '; }
old() { touch -t 202601010000 "$1"; }       # long since written

# The updater leaves an empty, non-executable file at versions/<ver> before the
# real download lands at a new inode. It never fills in.
: > "$V/9.9.1"; old "$V/9.9.1"
# A download still being written: executable and non-empty, but just modified.
head -c 4096 /dev/urandom > "$V/9.9.2"; chmod +x "$V/9.9.2"
# A finished binary.
head -c 4096 /dev/urandom > "$V/9.9.3"; chmod +x "$V/9.9.3"; old "$V/9.9.3"
snap

check "empty placeholder is not recorded"  '[ "$(rows 9.9.1)" = 0 ]'
check "file still being written is not recorded yet" '[ "$(rows 9.9.2)" = 0 ]'
check "finished binary is recorded"         '[ "$(rows 9.9.3)" = 1 ]'
want=$(shasum -a 256 "$V/9.9.3" | awk '{print $1}')
got=$(awk -F'\t' '$2 == "9.9.3" {print $6}' "$M")
check "its sha256 is the file's"           '[ "$got" = "$want" ]'

# Once the in-flight file settles, the next run picks it up.
old "$V/9.9.2"
snap
check "settled download is recorded next run" '[ "$(rows 9.9.2)" = 1 ]'
snap
check "a later run does not record it twice"  '[ "$(rows 9.9.2)" = 1 ]'

[ $fails -eq 0 ] && echo "claude-binary-snapshot: all passed" || { echo "claude-binary-snapshot: $fails FAILED"; exit 1; }
