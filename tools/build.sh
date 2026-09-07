#!/usr/bin/env bash
# postui — per-repo build script.
#
# Compiles every src/*.pdx, tests/*.pdx (when present), and tools/*.pdx
# to a loose ELF64 object under build-out/ via `paideia-as build`.
# postui itself is a userspace library -- src/*.pdx modules have no
# _start and no single link target; every source is a stand-alone
# module the downstream consumer link line pulls in. The tools/*.pdx
# files are the exception: each is a small tool binary (starting with
# postui.M5-002 scraper_example.pdx) that carries its own _start and
# is linked with the library objects into a standalone ELF program by
# the downstream packaging step.
#
# Resolves paideia-as via (in order):
#   1. $PAIDEIA_AS env var
#   2. sibling paideia-os checkout:
#      ../paideia-os/tools/paideia-as/target/release/paideia-as
#   3. $HOME/Development/PaideiaOS/tools/paideia-as/target/release/paideia-as
#   4. paideia-as on $PATH
#
# Requires paideia-as >= 0.34.0. postui's manifest pins that floor:
# 0.34 is the first release that carries the full mnemonic surface
# (2-op imul reg,reg, single-line pub let string literals, module-
# basename PascalCase enforcement, and the tightened test-mnemonic
# reservation) every postui source depends on. Older releases will
# either mis-encode or refuse to parse this tree.

set -euo pipefail
cd "$(dirname "$0")/.."

MIN_VERSION="0.34.0"

# --- help gate ---------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            cat <<'EOF'
usage: tools/build.sh

  Compiles every src/*.pdx (and tests/*.pdx if any exist) into loose
  build-out/*.o ELF64 object files via `paideia-as build --emit elf64`.
  No arguments are accepted at M1; a --profile split may land later if
  postui grows a satellite variant.
EOF
            exit 0
            ;;
        *)
            echo "[build] FAIL: unknown argument '$arg' (try --help)" >&2
            exit 2
            ;;
    esac
done

resolve_paideia_as() {
    if [ -n "${PAIDEIA_AS:-}" ] && [ -x "$PAIDEIA_AS" ]; then
        echo "$PAIDEIA_AS"; return
    fi
    for cand in \
        "../paideia-os/tools/paideia-as/target/release/paideia-as" \
        "$HOME/Development/PaideiaOS/tools/paideia-as/target/release/paideia-as"
    do
        if [ -x "$cand" ]; then
            echo "$cand"; return
        fi
    done
    if command -v paideia-as >/dev/null 2>&1; then
        command -v paideia-as; return
    fi
    return 1
}

version_ge() {
    # $1 = have, $2 = want ; returns 0 if have >= want
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

PA="$(resolve_paideia_as || true)"
if [ -z "$PA" ]; then
    echo "[build] FAIL: paideia-as not found. Set PAIDEIA_AS or clone paideia-os as a sibling." >&2
    exit 2
fi
VER="$("$PA" --version | awk '{print $2}')"
if ! version_ge "$VER" "$MIN_VERSION"; then
    echo "[build] FAIL: paideia-as $VER is too old, need >= $MIN_VERSION (found $PA)" >&2
    exit 2
fi
echo "[build] paideia-as $VER at $PA"

BUILD_DIR="build-out"
mkdir -p "$BUILD_DIR"

FAIL=0
COUNT=0

for pdx in src/*.pdx src/widgets/*.pdx src/input/*.pdx tools/*.pdx; do
    [ -f "$pdx" ] || continue
    COUNT=$((COUNT + 1))
    base="$(basename "$pdx")"
    obj="$BUILD_DIR/${base%.pdx}.o"
    if ! "$PA" build --emit elf64 "$pdx" -o "$obj" 2>&1; then
        FAIL=$((FAIL + 1))
    fi
done

if [ -d tests ]; then
    for pdx in tests/*.pdx; do
        [ -f "$pdx" ] || continue
        COUNT=$((COUNT + 1))
        obj="$BUILD_DIR/tests-$(basename "$pdx" .pdx).o"
        if ! "$PA" build --emit elf64 "$pdx" -o "$obj" 2>&1; then
            FAIL=$((FAIL + 1))
        fi
    done
fi

echo "[build] $COUNT source(s), $FAIL failure(s)"
[ "$FAIL" -eq 0 ] || exit 1
echo "[build] OK"
