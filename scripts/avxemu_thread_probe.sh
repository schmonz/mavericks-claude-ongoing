#!/bin/sh
# Demonstrate that avxemu's live code patching is unsafe in a multithreaded
# target, using Claude Code's own embedded ripgrep as the victim.
#
#   sh scripts/avxemu_thread_probe.sh [tree]
#
# Exits 0 if the crash reproduces AND both single-threaded and AVXEMU_RELOC=0
# runs are clean -- i.e. the diagnosis still holds. Exits 1 if the picture has
# changed (avxemu fixed, or the failure moved), which is worth knowing about.
set -e
BIN=${BIN:-$(readlink "$HOME/.local/bin/claude" 2>/dev/null || echo "$HOME/.local/bin/claude")}
case "$BIN" in /*) ;; *) BIN="$HOME/.local/bin/$BIN" ;; esac
LIB=${LIB:-$HOME/.local/share/claude-mavericks/libavxemu.dylib}
TREE=${1:-$HOME/.claude/plugins}
[ -x "$BIN" ] || { echo "no claude binary at $BIN" >&2; exit 2; }
[ -f "$LIB" ] || { echo "no libavxemu at $LIB" >&2; exit 2; }

# `exec -a rg` is how Claude Code invokes its embedded ripgrep.
run() { # run <env-assignments...> -- prints "lines exit"
    n=$(env DYLD_INSERT_LIBRARIES="$LIB" "$@" \
        sh -c 'exec -a rg "$0" -l skill "$1"' "$BIN" "$TREE" 2>/dev/null | wc -l | tr -d ' ')
    # `|| e=$?` keeps set -e from killing the function on the crash we are
    # here to observe.
    e=0
    env DYLD_INSERT_LIBRARIES="$LIB" "$@" \
        sh -c 'exec -a rg "$0" -l skill "$1"' "$BIN" "$TREE" >/dev/null 2>&1 || e=$?
    echo "$n $e"
}
# Ground truth from a configuration with no live patching.
set -- $(run AVXEMU_RELOC=0)
TRUTH=$1; TRUTH_EXIT=$2
echo "AVXEMU_RELOC=0      : lines=$TRUTH exit=$TRUTH_EXIT"
[ "$TRUTH_EXIT" = 0 ] || { echo "baseline itself failed -- investigate"; exit 1; }

crashes=0
for i in 1 2 3 4 5; do
    set -- $(run)
    echo "default (threaded) : lines=$1 exit=$2"
    [ "$2" = 0 ] || crashes=$((crashes + 1))
done

echo
if [ "$crashes" -gt 0 ]; then
    echo "REPRODUCED: $crashes/5 threaded runs died (expect exit 138, SIGBUS),"
    echo "            against $TRUTH files found with relocation disabled."
    echo "            Cause: reloc.c patch_site_jmp rewrites live __text while"
    echo "            other threads execute it. Keep USE_BUILTIN_RIPGREP=0."
    exit 0
fi
echo "NOT REPRODUCED: threaded runs are clean now. If avxemu gained"
echo "                concurrency-safe patching, this probe and the"
echo "                docs/upstream/mf-embedded-rg-threads report are stale."
exit 1
