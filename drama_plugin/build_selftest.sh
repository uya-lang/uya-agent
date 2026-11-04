#!/bin/sh
# Build entrypoint regression: cwd independence, output path and executable.

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
BUILD="$HERE/build.sh"
if [ ! -f "$BUILD" ]; then
    BUILD="$HERE/../build.sh"
fi
UYA=${UYA:-$ROOT/uya/bin/uya}
UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}
export UYA UYA_ROOT
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/custom/bin/drama"

check_binary() {
    binary=$1
    [ -x "$binary" ]
    version=$("$binary" version)
    case "$version" in
        'drama '*) ;;
        *) echo "FAIL: unexpected version output: $version"; exit 1 ;;
    esac
    echo "PASS: executable runs: $version"
}

cd "$TMP"
sh "$BUILD" "$OUT"
check_binary "$OUT"
mkdir -p "$TMP/default"
(
    cd "$TMP/default"
    sh "$BUILD"
)
check_binary "$TMP/default/build/drama"
