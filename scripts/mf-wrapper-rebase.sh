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
"""# Use the ripgrep in /usr/local/bin, not the copy embedded in the binary.
# KEEP THIS. The embedded rg is multithreaded and SIGBUSes under avxemu (5/5),
# emitting a random fraction of the matches first -- avxemu rewrites live __text
# while other threads run it. We are additionally covered by the
# DYLD_INSERT_LIBRARIES scrub in ~/.claude/settings.json, which keeps avxemu out
# of child processes, but this is the cheap belt to that braces.
# See docs/upstream/mf-embedded-rg-threads/REPORT.md.
export USE_BUILTIN_RIPGREP=0

# MF-LOCAL: the ugrep/bfs shims, unlike rg, are fine -- so upstream's
# `--allowedTools=Grep` (dropped at the bottom of this wrapper) is not needed to
# avoid a crash. Both died on 10.9 once -- bfs SIGILL 132, ugrep SIGSEGV 139 --
# from a __TEXT,__init_offsets constructor this dyld skips, leaving their SIMD
# dispatch table null; libSystemWrapper's init_offsets.c fixes it and ships.
# Rechecked on 2.1.251 with avxemu inserted: 218/218 and 326/326, exit 0, five
# runs each. See docs/native-search-recheck.md.
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

# 3. Drop --allowedTools. Upstream now emits every injected flag in the
#    =value form itself (our issue #8, fixed 2026-09-08), so the only remaining
#    difference here is that we do not want the flag at all.
src = sub(
"""# Claude Code's shell snapshots shadow `find` and `grep` with the embedded
# bfs/ugrep unless the Grep or Glob tool is named on the command line. Those
# shims re-exec the CLI binary under a different argv[0], which fails here, so
# opt in: the system find/grep stay visible and Grep/Glob run in-process.
set -- --allowedTools=Grep "$@"

exec "$REAL" "$@"
""",
"""# MF-LOCAL: upstream names Grep on the command line so the shell snapshots never
# shadow find/grep with the embedded bfs/ugrep. We want them shadowed: the shims
# work on this platform since libSystemWrapper's init_offsets.c started running
# the __TEXT,__init_offsets constructors 10.9's dyld skips, which is what had
# left their SIMD dispatch tables null (bfs SIGILL 132, ugrep SIGSEGV 139).
# Rechecked 218/218 and 326/326, five runs each -- see docs/native-search-recheck.md.
exec "$REAL" "$@"
""",
    "allowedTools line")

# 4. Attach avxemu by LINKAGE, not DYLD_INSERT_LIBRARIES, when a local build that
#    supports it is present. See docs/linkage-poc/ and
#    docs/upstream/mf-installer-link-avxemu/REPORT.md.
src = sub(
"""if [ -f "$MF/libavxemu.dylib" ] && ! sysctl -n machdep.cpu.leaf7_features 2>/dev/null | grep -qiw AVX2; then
    export DYLD_INSERT_LIBRARIES="$MF/libavxemu.dylib${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
fi
""",
"""NEED_AVXEMU=
if [ -f "$MF/libavxemu.dylib" ] && ! sysctl -n machdep.cpu.leaf7_features 2>/dev/null | grep -qiw AVX2; then
    NEED_AVXEMU=1
fi

# MF-LOCAL: prefer LINKING avxemu into the binary over asking dyld to insert it.
# Inserted, it is inherited by every child process and has to be scrubbed back
# off -- and a scrubbed child that re-execs the claude binary then runs
# unemulated, which is how the embedded bfs came to SIGILL 132. Linked, it covers
# exactly this one binary, cannot leak, survives env scrubbing, and also covers
# anyone running ~/.local/bin/claude directly instead of this wrapper.
#
# Gated on a local build because mavericksforever.com does not ship the two
# pieces this needs yet: `change_dylib` without -insert cannot add the load
# command, and a LINKED libavxemu without the sigaction/signal rebind does not
# degrade -- it hangs. $MFL is outside $MF precisely so an MF_GEN refetch cannot
# replace these with the versions that hang. Build with:
#     sh scripts/mf-build-local.sh   (mavericks-claude-ongoing)
MFL=$HOME/.local/share/claude-mavericks-local
LINK_AVXEMU=
if [ -n "$NEED_AVXEMU" ]; then
    if [ -f "$MFL/.ok" ] && [ -f "$MFL/libavxemu.dylib" ] && [ -x "$MFL/change_dylib" ]; then
        LINK_AVXEMU=1
    else
        export DYLD_INSERT_LIBRARIES="$MF/libavxemu.dylib${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
    fi
fi
""",
    "avxemu attach block")

src = sub(
"""ln -sf "$MF/libSystemWrapper.dylib" "$ALIAS_DIR/S.dylib" || { echo "claude: S alias failed" >&2; exit 1; }
ln -sf "$MF/libicucoreWrapper.dylib" "$ALIAS_DIR/I.dylib" || { echo "claude: I alias failed" >&2; exit 1; }
ln -sf "$MF/libc++.1.dylib" "$ALIAS_DIR/c++.1.dylib" || { echo "claude: c++ alias failed" >&2; exit 1; }
""",
"""# MF-LOCAL: two schemes, selected by the same $MFL gate that decides linkage.
#
# LINKED: reference every wrapper by its REAL name in its REAL directory, and
# create no aliases at all. Upstream needs the single-character S/I/c++ aliases
# for two reasons that are both now gone. The replacement name had to be no
# longer than the /usr/lib path it replaced, because there was no header room --
# -grow now makes 4144 bytes (macho_grow PR #12). And they had to sit outside
# versions/, which Claude Code's version housekeeping reaps -- with no aliases
# there is nothing to reap. libc++abi needs nothing either: libc++'s own
# @loader_path now resolves to $MF directly, so it finds its sibling.
#
# OTHERWISE: upstream's alias scheme, untouched. The shipped change_dylib cannot
# grow the header, so there the short names are still load-bearing.
if [ -n "$LINK_AVXEMU" ]; then
    SW="$MF/libSystemWrapper.dylib"
    IW="$MF/libicucoreWrapper.dylib"
    CW="$MF/libc++.1.dylib"
    AW="$MFL/libavxemu.dylib"
    # Sweep up aliases left by the old scheme, so a migrated install ends up as
    # clean as a fresh one. Symlinks only, and only these four names -- a hot
    # path is no place to delete anything it did not create.
    for a in S.dylib I.dylib c++.1.dylib A.dylib; do
        [ -L "$ALIAS_DIR/$a" ] && rm -f "$ALIAS_DIR/$a"
    done
else
    SW="@loader_path/../S.dylib"
    IW="@loader_path/../I.dylib"
    CW="@loader_path/../c++.1.dylib"
    AW=""
    ln -sf "$MF/libSystemWrapper.dylib" "$ALIAS_DIR/S.dylib" || { echo "claude: S alias failed" >&2; exit 1; }
    ln -sf "$MF/libicucoreWrapper.dylib" "$ALIAS_DIR/I.dylib" || { echo "claude: I alias failed" >&2; exit 1; }
    ln -sf "$MF/libc++.1.dylib" "$ALIAS_DIR/c++.1.dylib" || { echo "claude: c++ alias failed" >&2; exit 1; }
fi

# A binary that already links avxemu will not launch if that file is gone. Say
# so, instead of letting dyld fail cryptically on the user's next launch.
if head -c 1048576 "$REAL" 2>/dev/null | /usr/bin/grep -qF 'libavxemu.dylib' \\
   && [ ! -f "$MFL/libavxemu.dylib" ]; then
    echo "claude: $REAL links libavxemu.dylib but $MFL/libavxemu.dylib is missing." >&2
    echo "claude: re-run 'sh scripts/mf-build-local.sh' in mavericks-claude-ongoing." >&2
    exit 1
fi
""",
    "dylib reference scheme")

src = sub(
"""if ! head -c 1048576 "$REAL" 2>/dev/null | /usr/bin/grep -qE '@loader_path/\\.\\./S\\.dylib'; then""",
"""# -qF, not -qE: these are paths, and the scheme's own spelling is what we look
# for, so a binary patched under the other scheme re-patches into this one.
lc_has() { head -c 1048576 "$REAL" 2>/dev/null | /usr/bin/grep -qF "$1"; }
if ! lc_has "$SW" || { [ -n "$LINK_AVXEMU" ] && ! lc_has "$AW"; }; then""",
    "patch-probe condition")

src = sub(
"""    "$MF/change_dylib"    "$T" -strip-lc uuid -strip-lc codesig \\
        -change "/usr/lib/libSystem.B.dylib"  "@loader_path/../S.dylib" \\
        -change "/usr/lib/libicucore.A.dylib" "@loader_path/../I.dylib" \\
        -change "/usr/lib/libc++.1.dylib"     "@loader_path/../c++.1.dylib" \\
        >/dev/null || { echo "claude: change_dylib failed" >&2; exit 1; }
""",
"""    # patch_macho and add_version_min both detect their own work and pass
    # through, and a -change whose old path is already rewritten is a no-op, so
    # re-running the whole chain on an already-patched binary just to add
    # A.dylib is safe. That is what makes the two-condition probe above work.
    # Every known spelling maps to the current scheme's target, so a binary
    # patched under either scheme converges on this one. A -change whose old path
    # is absent is a no-op, and one where old == new is harmless; both verified.
    # (Unquoted $2 is deliberate word-splitting for the optional -insert, as
    # upstream does; it assumes no spaces in these paths.)
    mf_change_dylib() {
        "$1" "$T" -strip-lc uuid -strip-lc codesig $2 \\
            -change "/usr/lib/libSystem.B.dylib"    "$SW" \\
            -change "/usr/lib/libicucore.A.dylib"   "$IW" \\
            -change "/usr/lib/libc++.1.dylib"       "$CW" \\
            -change "@loader_path/../S.dylib"       "$SW" \\
            -change "@loader_path/../I.dylib"       "$IW" \\
            -change "@loader_path/../c++.1.dylib"   "$CW" \\
            -change "$MF/libSystemWrapper.dylib"    "$SW" \\
            -change "$MF/libicucoreWrapper.dylib"   "$IW" \\
            -change "$MF/libc++.1.dylib"            "$CW" \\
            >/dev/null
    }
    if [ -n "$LINK_AVXEMU" ]; then
        # Only the local change_dylib has -insert. -insert, not -add: an appended
        # dependency initialises AFTER the ones already there, and the emulator
        # has to be armed first.
        # -grow is needed now: the real names are longer than the paths they
        # replace, so the load commands no longer fit the stock pad. Only the
        # local change_dylib can do that safely (macho_grow PR #12).
        # -insert only when there is no avxemu reference under EITHER spelling.
        # A binary already carrying @loader_path/../A.dylib gets the -change
        # above; inserting as well would give it two.
        AVXOPS="-grow -change @loader_path/../A.dylib $AW"
        if ! lc_has "$AW" && ! lc_has "@loader_path/../A.dylib"; then
            AVXOPS="$AVXOPS -insert $AW"
        fi
        mf_change_dylib "$MFL/change_dylib" "$AVXOPS" || {
            # Degrade all the way back to upstream's configuration, not part of
            # the way. The long names only fit because -grow made room, and the
            # shipped change_dylib cannot grow, so falling back means the SHORT
            # names and the aliases they need -- and avxemu via the env var.
            # Retrying with $SW still absolute would just fail again.
            echo "claude: could not link avxemu into $(basename "$REAL"); using DYLD_INSERT_LIBRARIES" >&2
            LINK_AVXEMU=
            SW="@loader_path/../S.dylib"
            IW="@loader_path/../I.dylib"
            CW="@loader_path/../c++.1.dylib"
            ln -sf "$MF/libSystemWrapper.dylib"  "$ALIAS_DIR/S.dylib"     || { echo "claude: S alias failed" >&2; exit 1; }
            ln -sf "$MF/libicucoreWrapper.dylib" "$ALIAS_DIR/I.dylib"     || { echo "claude: I alias failed" >&2; exit 1; }
            ln -sf "$MF/libc++.1.dylib"          "$ALIAS_DIR/c++.1.dylib" || { echo "claude: c++ alias failed" >&2; exit 1; }
            export DYLD_INSERT_LIBRARIES="$MF/libavxemu.dylib${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
            rm -f "$T"
            "$MF/patch_macho"     "$REAL" "$T" >/dev/null || { echo "claude: patch_macho failed"     >&2; exit 1; }
            "$MF/add_version_min" "$T"         >/dev/null || { echo "claude: add_version_min failed" >&2; exit 1; }
            mf_change_dylib "$MF/change_dylib" "" || { echo "claude: change_dylib failed" >&2; exit 1; }
        }
    else
        mf_change_dylib "$MF/change_dylib" "" || { echo "claude: change_dylib failed" >&2; exit 1; }
    fi
""",
    "change_dylib call")

sys.stdout.write(src)
PY
