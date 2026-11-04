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
VERSION=$(sed -n 's/.*const VERSION:.*"\([0-9][0-9.]*\)".*/\1/p' \
    "$HERE/src/main.uya")
[ -n "$VERSION" ] || { echo "FAIL: source version not found"; exit 1; }
export UYA UYA_ROOT
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/custom/bin/drama"

check_binary() {
    binary=$1
    [ -x "$binary" ]
    version=$("$binary" version)
    [ "$version" = "drama $VERSION" ] || {
        echo "FAIL: expected drama $VERSION, got: $version"
        exit 1
    }
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
