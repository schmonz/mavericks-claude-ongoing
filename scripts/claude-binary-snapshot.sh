#!/bin/sh
# Preserve every distinct Claude Code binary this machine runs, so that a
# crashing build can be diffed against a working one after the fact.
#
# Why this exists: on 2026-09-19 the 2.1.278 binary installed at 13:20 crashed
# on ~2/3 of interactive launches (fixed fault site, varying near-null pointer).
# At 20:22 the auto-updater re-downloaded and re-patched the same version and
# the crash vanished -- but the bad binary had already been unlinked, so there
# was nothing left to diff. Two 2.1.278 binaries, same version, same size, same
# patch chain, opposite behaviour, and no way to find out how they differed.
#
# How: a hard link costs nothing while the file exists, and keeps the inode --
# and therefore the exact bytes -- alive after the updater or the wrapper
# renames a replacement over it. We catch both the pristine download and the
# patched result, because patch_macho builds a copy and renames, which makes a
# new inode.
#
# Install: launchd agent running this every 60s. Remove by unloading the agent
# and deleting $SNAPDIR.

set -e

VERSIONS=$HOME/.local/share/claude/versions
SNAPDIR=$HOME/.local/share/claude-binary-snapshots
MANIFEST=$SNAPDIR/manifest.tsv
KEEP=12                    # distinct inodes to retain; oldest pruned first

[ -d "$VERSIONS" ] || exit 0
mkdir -p "$SNAPDIR"
[ -f "$MANIFEST" ] || printf 'when\tversion\tinode\tsize\tpatched\tsha256\tlink\n' > "$MANIFEST"

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else echo "-"
    fi
}

# A binary is "patched" once our wrapper has rewritten its load commands. Cap
# the read: the load commands live in the first few KB, and these files are
# ~227 MB. Call /usr/bin/grep by path -- with native file search enabled the
# shell snapshots shadow `grep` with the embedded ugrep, which reports no match
# on binary input.
patched_p() {
    if head -c 1048576 "$1" 2>/dev/null | /usr/bin/grep -qF 'libavxemu.dylib'; then
        echo patched
    else
        echo pristine
    fi
}

for bin in "$VERSIONS"/*; do
    [ -f "$bin" ] || continue
    case $bin in *.mf-tmp.*) continue ;; esac          # a patch in flight

    ver=$(basename "$bin")
    ino=$(stat -f %i "$bin")
    link=$SNAPDIR/$ver.$ino.bin

    # Already captured this exact inode? Nothing to do. This is the common
    # case and must stay cheap: no hashing, no reading of the file.
    [ -e "$link" ] && continue

    ln "$bin" "$link" 2>/dev/null || continue         # same filesystem required

    size=$(stat -f %z "$link")
    state=$(patched_p "$link")
    sum=$(sha256_of "$link")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$ver" "$ino" "$size" "$state" "$sum" "$link" \
        >> "$MANIFEST"
done

# Prune oldest snapshots beyond $KEEP. Only unlinks our own hard links, never
# anything under $VERSIONS -- deleting a link here cannot affect a live install.
count=$(ls -1 "$SNAPDIR"/*.bin 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" -gt "$KEEP" ]; then
    ls -1t "$SNAPDIR"/*.bin | tail -n +$((KEEP + 1)) | while read -r old; do rm -f "$old"; done
fi
