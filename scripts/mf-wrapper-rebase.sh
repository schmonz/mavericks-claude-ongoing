#!/bin/sh
# Rebase our local wrapper edits onto the wrapper that mavericksforever.com's
# install.sh currently emits, and print the result on stdout.
#
#   sh scripts/mf-wrapper-rebase.sh > /tmp/claude-wrapper
#   diff /usr/local/bin/claude /tmp/claude-wrapper
#   sudo install -m 755 /tmp/claude-wrapper /usr/local/bin/claude
#
# Every edit is anchored to exact upstream text and the script dies if an anchor
# has moved, so upstream drift shows up here instead of silently dropping one of
# our fixes. Set INSTALLER to rebase against a local copy instead of the CDN.
set -e
INSTALLER=${INSTALLER:-https://mavericksforever.com/claude/install.sh}
T=$(mktemp -t mf-wrapper-rebase)
trap 'rm -f "$T" "$T.w"' EXIT INT TERM
case "$INSTALLER" in
    http*) curl -fsSL "$INSTALLER" -o "$T" || { echo "fetch failed: $INSTALLER" >&2; exit 1; } ;;
    *)     cp "$INSTALLER" "$T" ;;
esac
awk '/^cat > "\$TMP\/claude" <</,/^WRAPPER_EOF$/' "$T" | sed '1d;$d' > "$T.w"
[ -s "$T.w" ] || { echo "could not extract the wrapper heredoc from $INSTALLER" >&2; exit 1; }

python3 - "$T.w" <<'PY'
import sys

src = open(sys.argv[1]).read()

def sub(old, new, what):
    if src.count(old) != 1:
        sys.exit("anchor moved (%d matches) — rebase by hand: %s" % (src.count(old), what))
    return src.replace(old, new)

# 1. Native file search stays ON. Upstream disables the embedded ripgrep and
#    names Grep on the command line so the snapshot shims never install; both
#    were worked around a crash that libSystemWrapper's init_offsets.c fixed.
src = sub(
"""# Use the ripgrep in /usr/local/bin, not the copy embedded in the binary.
export USE_BUILTIN_RIPGREP=0
""",
"""# MF-LOCAL: native file search left enabled (upstream sets USE_BUILTIN_RIPGREP=0
# here and passes --allowedTools Grep at the bottom). Both exist because Claude
# Code's shell snapshots shadow `grep`/`find` with the binary's embedded
# ugrep/bfs, and on 10.9 both died -- bfs SIGILL 132, ugrep SIGSEGV 139. Same
# cause for both: a __TEXT,__init_offsets constructor this dyld skips, leaving
# their SIMD dispatch table null. libSystemWrapper's init_offsets.c fixes it, and
# it ships. Rechecked on 2.1.251: invoked as the shim does (argv[0] = ugrep/bfs),
# both exit 0 with and without avxemu inserted, and agree with the real tools.
# See docs/native-search-recheck.md. Revert = restore the two upstream bits.
""",
    "USE_BUILTIN_RIPGREP export")

# 2. The patch-detection probe must call /usr/bin/grep by path. Upstream can use
#    bare `grep` only because its --allowedTools Grep keeps the shim uninstalled;
#    with the shim live, the embedded ugrep reports no match on binary input and
#    the binary would be re-patched on every launch.
src = sub(
"""# -a off: BSD grep's text mode stops each line at the load commands' NUL padding.""",
"""# -a off: BSD grep's text mode stops each line at the load commands' NUL padding.
# Call /usr/bin/grep by path: with native file search enabled (above) the shell
# snapshots shadow `grep` with the embedded ugrep, which reports no match on
# binary input -- and a false negative here re-patches the binary every launch.""",
    "patch-probe comment")
src = sub(
"""| grep -qE '@loader_path/\\.\\./S\\.dylib'""",
"""| /usr/bin/grep -qE '@loader_path/\\.\\./S\\.dylib'""",
    "patch-probe grep call")

# 3. Injected flags in equals form, and no --allowedTools. `--mcp-config
#    <configs...>` and `--allowedTools <tools...>` are both variadic, so the
#    space form keeps consuming tokens and swallows the user's first positional.
src = sub(
"""CU="$MF/computer-use"
if [ -f "$CU/mcp-config.json" ] && [ -x "$CU/mcp_server.py" ]; then
    set -- --mcp-config "$CU/mcp-config.json" "$@"
fi
if [ -f "$MF/settings.json" ]; then
    set -- --settings "$MF/settings.json" "$@"
fi

# Claude Code's shell snapshots shadow `find` and `grep` with the embedded
# bfs/ugrep unless the Grep or Glob tool is named on the command line. Those
# shims re-exec the CLI binary under a different argv[0], which fails here, so
# opt in: the system find/grep stay visible and Grep/Glob run in-process.
set -- --allowedTools Grep "$@"

exec "$REAL" "$@"
""",
"""#
# MF-LOCAL: pass injected flags as --flag=value, not --flag value. `--mcp-config
# <configs...>` is variadic (it accepts several space-separated files), so in the
# space form it keeps eating tokens and swallows the user's first positional:
# `claude mcp list` dies with "MCP config file not found: $PWD/mcp", and
# `claude install 2.1.197` with ".../install". Bare `claude` never shows it,
# which is why it survives upstream. The equals form binds exactly one value.
# `--allowedTools <tools...>` is variadic the same way -- upstream's
# `--allowedTools Grep "$@"` eats `mcp list` too -- and it is dropped here
# anyway, since the search shims it was avoiding work on this platform.
CU="$MF/computer-use"
ARGS=""
[ -f "$MF/settings.json" ] && ARGS="--settings=$MF/settings.json"
if [ -f "$CU/mcp-config.json" ] && [ -x "$CU/mcp_server.py" ]; then
    ARGS="$ARGS --mcp-config=$CU/mcp-config.json"
fi

exec "$REAL" $ARGS "$@"
""",
    "injected flags block")

sys.stdout.write(src)
PY
