#!/bin/sh
# fetch-179.sh <version> — download + checksum-verify an upstream Claude Code
# binary and install it to ~/.local/share/claude/versions/<version>.
#
# Despite the name it is parameterized: `sh fetch-179.sh 2.1.183`.
# Anthropic reaps old versions from the symlink/autoupdater, so re-fetch as needed.
set -eu

VERSION="${1:?usage: sh fetch-179.sh <version>}"
PLATFORM="${2:-darwin-x64}"
BASE="https://downloads.claude.ai/claude-code-releases"
DEST="$HOME/.local/share/claude/versions/$VERSION"
BIN="$DEST.download"

mkdir -p "$(dirname "$DEST")"

# manifest carries the sha256; pass it to python as a FILE arg (heredoc on stdin
# would clobber the data we pipe). BSD mktemp (macOS 10.9) needs a template.
MF=$(mktemp /tmp/claude-manifest.XXXXXX)
curl -fsSL -o "$MF" "$BASE/$VERSION/manifest.json"

curl -fL -o "$BIN" "$BASE/$VERSION/$PLATFORM/claude"

WANT=$(python3 - "$MF" "$PLATFORM" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); plat=sys.argv[2]
# manifest shape varies; try platforms[plat].checksum then top-level checksum
plats=m.get("platforms",{})
e=plats.get(plat) or {}
print(e.get("checksum") or e.get("sha256") or m.get("checksum") or "")
PY
)
GOT=$(shasum -a 256 "$BIN" | awk '{print $1}')
if [ -n "$WANT" ] && [ "$WANT" != "$GOT" ]; then
    echo "checksum mismatch for $VERSION: want $WANT got $GOT" >&2
    rm -f "$BIN" "$MF"; exit 1
fi
[ -n "$WANT" ] || echo "warning: no checksum in manifest; installing unverified" >&2

chmod +x "$BIN"
mv "$BIN" "$DEST"
rm -f "$MF"
echo "installed $VERSION -> $DEST (sha256 $GOT)"
