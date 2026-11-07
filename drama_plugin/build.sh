#!/bin/sh
# Build the standalone Drama executable.
# Usage: build.sh [output-path]
# UYA and UYA_ROOT may select an external compiler and standard library.

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}
OUT=${1:-build/drama}

case "$OUT" in
    /*) ;;
    *) OUT="$PWD/$OUT" ;;
esac
mkdir -p "$(dirname -- "$OUT")"
BUILD_TMP=$(mktemp -d /tmp/drama-build.XXXXXX)
trap 'rm -rf "$BUILD_TMP"' EXIT
"$UYA" build \
    "$HERE/src/main.uya" "$HERE/src/bytes.uya" \
    "$HERE/src/json_min.uya" "$HERE/src/json_out.uya" \
    "$HERE/src/registry.uya" "$HERE/src/schema.uya" \
    "$HERE/src/dispatch.uya" "$HERE/src/store.uya" \
    "$HERE/src/project.uya" "$HERE/src/digest.uya" \
    "$HERE/src/asset.uya" "$HERE/src/bible.uya" \
    "$HERE/src/canon.uya" "$HERE/src/httpc.uya" \
    "$HERE/src/llm.uya" "$HERE/src/story.uya" \
    "$HERE/src/context.uya" "$HERE/src/task.uya" \
    "$HERE/src/board.uya" "$HERE/src/provider.uya" \
    "$HERE/src/qa.uya" "$HERE/src/audit.uya" \
    "$HERE/src/assemble.uya" "$HERE/src/index.uya" \
    "$HERE/src/series.uya" "$HERE/src/ops.uya" "$HERE/src/media_ops.uya" \
    "$HERE/src/verify_ops.uya" "$HERE/src/queue_ops.uya" "$HERE/src/pipeline_ops.uya" \
    "$HERE/src/server.uya" -o "$BUILD_TMP/drama"
mv "$BUILD_TMP/drama" "$OUT"
printf 'Built %s (%s bytes)\n' "$OUT" "$(wc -c < "$OUT")"
