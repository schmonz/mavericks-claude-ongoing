#!/bin/sh
# Build the two artifacts the linked-avxemu wrapper needs, which mavericksforever.com
# does not ship yet, into a directory install.sh never touches.
#
#   sh scripts/mf-build-local.sh
#
# Why local builds at all: the CDN's libavxemu.dylib and change_dylib are (as of
# 2026-09-08) byte-identical to what is installed, and neither has what linkage
# needs -- `change_dylib` has no -insert, and libavxemu has no AVXEMU_NO_REBIND.
# Both fixes are merged in ../Mavericks-Porting-Resources master; upstream simply
# has not rebuilt. Check the artifact, not the repo.
#
# Why a separate directory: $MF is wiped and refetched whenever the wrapper's
# MF_GEN stops matching $MF/.generation. A local build placed there would be
# silently replaced by the non-rebind one, and a LINKED non-rebind avxemu does
# not degrade -- it hangs (--version never returns, killed at 90s, 3/3). Out of
# harm's way instead, with a stamp the wrapper can test.
set -e

MPR=${MPR:-$HOME/Documents/code/trees/Mavericks-Porting-Resources}
MFL=${MFL:-$HOME/.local/share/claude-mavericks-local}
OUT=${OUT:-/tmp/mf-build-local.$$}
CC=${CC:-clang}

[ -d "$MPR/avxemu" ] || { echo "no avxemu tree at $MPR -- set MPR" >&2; exit 1; }
trap 'rm -rf "$OUT"' EXIT INT TERM
mkdir -p "$OUT" "$MFL"

# The stamp is written last and removed first: a build that dies halfway leaves
# the directory unstamped, and the wrapper falls back to DYLD_INSERT_LIBRARIES
# rather than linking against a half-built dylib.
rm -f "$MFL/.ok"

CORE="-O2 -Wall -std=c11 -msse4.2 -mno-avx -mno-fma -Isrc"
quiet() { grep -vE "warning:|note:|implicitly declaring|please include|^ *\^|^ *~|generated\." || true; }

echo "[1] change_dylib (needs -insert AND -strip-lc)..."
$CC -O2 -Wall -std=c11 -I"$MPR" "$MPR/change_dylib.c" -o "$OUT/change_dylib" 2>&1 | quiet
for flag in -insert -strip-lc -grow; do
    "$OUT/change_dylib" 2>&1 | grep -q -- "$flag" \
        || { echo "    built change_dylib lacks $flag -- wrong tree?" >&2; exit 1; }
done
echo "    ok"

cd "$MPR/avxemu"

echo "[2] avxemu runtime core (SSE4.2 only, no VEX)..."
PURE=""
for f in exec exec_bmi softfma names decode lde patch_mem tramp reloc handler; do
    $CC $CORE -c src/$f.c -o "$OUT/$f.o" 2>&1 | quiet
    PURE="$PURE $OUT/$f.o"
done
$CC $CORE -c src/selftest.c -o "$OUT/selftest_c.o" 2>&1 | quiet
$CC -c src/selftest.s -o "$OUT/selftest.o"
$CC -c src/tramp.s     -o "$OUT/tramp_s.o"
ASM="$OUT/selftest.o $OUT/selftest_c.o $OUT/tramp_s.o"

# The hot path must contain no VEX: it runs on the CPU that cannot execute VEX.
leak=$(otool -tV $PURE 2>/dev/null | awk -F'\t' '$2 ~ /^v/{print $2}' | sort -u)
[ -z "$leak" ] || { echo "    VEX LEAK: $leak" >&2; exit 1; }
echo "    clean"

# build.sh steps 3, 4 and 6b are differential oracles against real AVX2/FMA/BMI
# hardware; they cannot run on this CPU and are not rebuilt here. They were
# silicon-checked on the AVX2 box for this same tree (see docs/FINDINGS.md).
# Everything below is either hermetic or exercises the 10.9 loader, so it is
# exactly the part that box could NOT check.

echo "[3] hermetic emulation tests..."
run() {
    name=$1; shift
    $CC $CORE -c "test/$name.c" -o "$OUT/$name.o" 2>&1 | quiet
    $CC $CORE "$OUT/$name.o" "$@" $PURE $ASM -o "$OUT/$name"
}
$CC -c test/stubs.s   -o "$OUT/stubs.o"
$CC -c test/memtest.s -o "$OUT/memtest_s.o"
$CC -c test/bmimem.s  -o "$OUT/bmimem_s.o"
$CC -c test/tramp_harness.s -o "$OUT/tramp_harness.o"
run inject    "$OUT/stubs.o";        "$OUT/inject"    | tail -1 | sed 's/^/    inject:    /'
run memtest   "$OUT/memtest_s.o";    "$OUT/memtest"   | tail -1 | sed 's/^/    memtest:   /'
run bmimem    "$OUT/bmimem_s.o";     "$OUT/bmimem"    | tail -1 | sed 's/^/    bmimem:    /'
run tramptest "$OUT/tramp_harness.o";"$OUT/tramptest" | tail -1 | sed 's/^/    tramptest: /'
run overread;                        "$OUT/overread"  | tail -1 | sed 's/^/    overread:  /'
# No `| tail` on these two: set -e must stop the build on a mismatch.
run reloctest;   AVXEMU_DISABLE=1 AVXEMU_FORCETRAMP=1 "$OUT/reloctest" | sed 's/^/    reloctest: /'
run nativetest;  AVXEMU_DISABLE=1                     "$OUT/nativetest" | sed 's/^/    native:    /'
$CC -O2 -std=c11 -Isrc test/zcnt16.c "$OUT/decode.o" "$OUT/exec_bmi.o" "$OUT/names.o" \
    -o "$OUT/zcnt16" 2>&1 | quiet
"$OUT/zcnt16" | tail -1 | sed 's/^/    zcnt16:    /'

echo "[4] linking the dylib..."
# -install_name is the absolute path it will live at: the binary's LC_LOAD_DYLIB
# says @loader_path/../A.dylib and resolves through a symlink, so this only has
# to be something dyld will not try to search for.
$CC -dynamiclib -O2 -msse4.2 -mno-avx -mno-fma \
    -install_name "$MFL/libavxemu.dylib" \
    $PURE $ASM -o "$OUT/libavxemu.dylib"
strings -a "$OUT/libavxemu.dylib" >/dev/null 2>&1 || true
grep -q AVXEMU_NO_REBIND "$OUT/libavxemu.dylib" \
    || { echo "    built dylib has no rebind (AVXEMU_NO_REBIND absent) -- wrong tree?" >&2; exit 1; }
echo "    ok"

echo "[5] selftest through the INSERTED path (build.sh step 8)..."
AVXEMU_SELFTEST=1 DYLD_INSERT_LIBRARIES="$OUT/libavxemu.dylib" /usr/bin/true \
    || { echo "    self-test FAILED" >&2; exit 1; }
echo "    ok"

echo "[6] installing to $MFL (unstamped)..."
# Installed before the linked test, not after: the dylib's -install_name is this
# absolute path, so a program linked against it can only be run once the file is
# actually there. The stamp still comes last, so a failure below leaves the
# directory present but unstamped -- and the wrapper keeps inserting.
install -m 755 "$OUT/change_dylib"    "$MFL/change_dylib"
install -m 644 "$OUT/libavxemu.dylib" "$MFL/libavxemu.dylib"
echo "    $MFL/change_dylib"
echo "    $MFL/libavxemu.dylib"

echo "[7] rebind through the LINKED path (build.sh step 8i) -- the whole point..."
# 10.9's dyld honours __DATA,__interpose only for DYLD_INSERT_LIBRARIES images,
# so linked avxemu must rebind sigaction/signal itself or the app's SIGILL
# handler wins and emulation dies at the first faulting instruction. Linked
# against the INSTALLED dylib, so this tests the artifact at the path the
# patched claude binary will resolve A.dylib to.
$CC -O0 test/linkhook.c "$MFL/libavxemu.dylib" -o "$OUT/linkhook"
"$OUT/linkhook"                    || { echo "    linked-load rebind FAILED" >&2; exit 1; }
AVXEMU_NO_REBIND=1 "$OUT/linkhook" || { echo "    negative control FAILED" >&2; exit 1; }
echo "    rebind holds, and the negative control still detects its absence"

(cd "$MPR" && git rev-parse HEAD) > "$MFL/.ok"
echo "[8] stamped $(cat "$MFL/.ok") -- the wrapper may now link instead of insert"
