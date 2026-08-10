#!/bin/sh
# try_latest.sh <version> [arm]
#
# Isolated test of an alternate Claude Code version on this no-AVX2 machine,
# WITHOUT touching the live launcher, the live ~/.local/bin/claude symlink, or
# the live plugin tree. Everything runs in a throwaway HOME; the version binary
# is shared read-write only for the in-place Mach-O patch (which that version
# needs anyway and which leaves the pinned-safe 2.1.179 untouched).
#
# Arms:
#   smoke  — run the broadened wrapper's `--version` (folds the copied tree,
#            runs the preflight, patches the binary): proves the patch applies
#            to this version and the binary launches. Prints the version.
#   A      — DEFENDED: broadened wrapper folds the copied plugin tree, then
#            measure TIME-TO-IDLE. Expect it idles (TTIDLE=<sec>).
#   B      — CONTROL: poison using-superpowers/SKILL.md (the SessionStart hook
#            reads it) and bypass the defense (CLAUDE_MF_ALLOW_WIDE_HOOKS=1).
#            Expect a hang (TTIDLE=none) — proves this version IS susceptible so
#            arm A is a meaningful pass, not a version that never spins.
#   all    — smoke, then A, then B (default).
set -e
VER=${1:?usage: try_latest.sh <version> [smoke|A|B|all]}
ARM=${2:-all}

MC=$(cd "$(dirname "$0")/.." && pwd)
WRAP="$MC/scripts/claude-wrapper-defended"
VBIN="$HOME/.local/share/claude/versions/$VER"
PROJECT=${TRY_PROJECT:-/Users/schmonz/Documents/code/trees/trusttest}
CH=/tmp/try_latest_home
[ -x "$VBIN" ] || { echo "no such version binary: $VBIN" >&2; exit 1; }
[ -d "$PROJECT" ] || { echo "no trusted test project: $PROJECT" >&2; exit 1; }

build_home() {
    rm -rf "$CH"; mkdir -p "$CH/.local/share" "$CH/.local/bin" "$CH/.claude"
    ln -sf "$HOME/.local/share/claude"           "$CH/.local/share/claude"
    ln -sf "$HOME/.local/share/claude-mavericks" "$CH/.local/share/claude-mavericks"
    ln -sf "$VBIN"                               "$CH/.local/bin/claude"   # pin to $VER
    cp -R "$HOME/.claude/plugins" "$CH/.claude/plugins" 2>/dev/null || true
    [ -f "$HOME/.claude/settings.json" ] && cp "$HOME/.claude/settings.json" "$CH/.claude/settings.json"
    python3 - "$PROJECT" > "$CH/.claude.json" <<'PY'
import json, sys
print(json.dumps({"projects": {sys.argv[1]: {"hasTrustDialogAccepted": True,
      "projectOnboardingSeenCount": 9}}, "hasCompletedOnboarding": True}))
PY
}

run_smoke() {
    build_home
    echo "=== SMOKE ($VER): patch + launch via broadened wrapper ==="
    OUT=$(cd "$PROJECT" && HOME="$CH" "$WRAP" --version 2>&1) || true
    echo "$OUT"
    case "$OUT" in *"$VER"*) echo "SMOKE OK: launched $VER";; *) echo "SMOKE FAIL: did not report $VER";; esac
}

run_A() {
    build_home
    echo "=== ARM A ($VER, DEFENDED): expect idle ==="
    R=$(cd "$PROJECT" && HOME="$CH" LAUNCHER="$WRAP" python3 "$MC/scripts/pyte_ttidle.py" 120 2>&1 | tail -1)
    echo "ARM A: $R"
    case "$R" in
      *TTIDLE=none*) echo "ARM A FAIL: defended $VER still spins.";;
      *TTIDLE=*)     echo "ARM A PASS: defended $VER idles.";;
      *)             echo "ARM A INCONCLUSIVE.";;
    esac
}

run_B() {
    build_home
    # poison the file the SessionStart hook emits, and turn the defense OFF.
    SK="$CH/.claude/plugins/cache/superpowers-marketplace/superpowers/5.1.0/skills/using-superpowers/SKILL.md"
    if [ -f "$SK" ]; then printf '\nControl poison: em-dash \342\200\224 here.\n' >> "$SK"; else
        echo "ARM B SKIP: no using-superpowers SKILL.md to poison"; return; fi
    echo "=== ARM B ($VER, CONTROL, defense OFF, poisoned hook): expect hang ==="
    R=$(cd "$PROJECT" && HOME="$CH" CLAUDE_MF_ALLOW_WIDE_HOOKS=1 LAUNCHER="$WRAP" \
        python3 "$MC/scripts/pyte_ttidle.py" 70 2>&1 | tail -1)
    echo "ARM B: $R"
    case "$R" in
      *TTIDLE=none*) echo "ARM B PASS (control reproduces): $VER hangs on a wide hook.";;
      *TTIDLE=*)     echo "ARM B UNEXPECTED: $VER idled even with a poisoned hook — is it susceptible?";;
      *)             echo "ARM B INCONCLUSIVE.";;
    esac
}

case "$ARM" in
    smoke) run_smoke ;;
    A)     run_A ;;
    B)     run_B ;;
    all)   run_smoke; echo; run_A; echo; run_B ;;
    *)     echo "unknown arm: $ARM" >&2; exit 1 ;;
esac
