#!/bin/sh
# drama_plugin/pack.sh — 打一个可交付包（P11「发布」的第一段）
#
# 产出 dist/drama-<version>/：
#   bin/drama            编译好的单可执行
#   docs/                设计、TODO、状态、评审、P0 结论
#   src/                 源码（可复现）
#   selftest/            全部验收脚本 + proto 原型
#   README.md            怎么跑、验收到哪一步
# 再打一个 tar.gz 并打印 SHA-256。
#
# 用法：sh drama_plugin/pack.sh [输出目录]
#
# 注意：包里不含 uya 工具链（体积大且项目相关），README 里写清楚需要 uya 0.11.0。

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}
OUT=${1:-$ROOT/dist}

VERSION=$(grep -o '"0\.[0-9]*\.[0-9]*"' "$HERE/src/main.uya" | head -1 | tr -d '"')
[ -n "$VERSION" ] || VERSION=0.0.0
PKG="drama-$VERSION"

SRC="$HERE/src/main.uya $HERE/src/bytes.uya $HERE/src/json_min.uya \
$HERE/src/json_out.uya $HERE/src/registry.uya $HERE/src/schema.uya \
$HERE/src/dispatch.uya $HERE/src/store.uya $HERE/src/project.uya \
$HERE/src/digest.uya $HERE/src/asset.uya $HERE/src/bible.uya \
$HERE/src/canon.uya $HERE/src/httpc.uya $HERE/src/llm.uya \
$HERE/src/story.uya $HERE/src/context.uya $HERE/src/task.uya \
$HERE/src/board.uya $HERE/src/provider.uya $HERE/src/qa.uya \
$HERE/src/audit.uya $HERE/src/assemble.uya $HERE/src/index.uya \
$HERE/src/series.uya $HERE/src/ops.uya $HERE/src/server.uya"

mkdir -p "$OUT"
STAGE="$OUT/$PKG"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/docs" "$STAGE/src" "$STAGE/selftest"

echo "== 编译 =="
"$UYA" build $SRC -o "$STAGE/bin/drama"
echo "   bin/drama $(wc -c < "$STAGE/bin/drama") 字节"

echo "== 收集文件 =="
cp "$HERE"/docs/*.md "$STAGE/docs/"
cp "$HERE"/src/*.uya "$STAGE/src/"
cp "$HERE"/*_selftest.sh "$STAGE/selftest/"
cp -r "$HERE/proto" "$STAGE/selftest/proto"
# 验收脚本按「脚本目录下的 src/」找源码，包里就照这个布局放一份
cp -r "$HERE/src" "$STAGE/selftest/src"
rm -f "$STAGE"/selftest/proto/*.log 2>/dev/null || true

cat > "$STAGE/README.md" <<README
# drama $VERSION

短剧生产插件的可交付包。**不含 Uya 工具链**：运行时需要 uya 0.11.0
（本仓 \`uya/bin/uya\` + \`uya/stdlib\`）。

## 怎么跑

\`\`\`sh
./bin/drama version
./bin/drama health --data-dir /tmp/drama-data
./bin/drama mcp serve --data-dir /tmp/drama-data     # stdio MCP，三工具
./bin/drama worker run --data-dir /tmp/drama-data    # 扫未完成任务
\`\`\`

## 怎么验

\`\`\`sh
UYA=<uya 编译器路径> UYA_ROOT=<标准库路径> sh selftest/p1_selftest.sh
# 或一次跑完：
for f in selftest/p*_selftest.sh; do sh "\$f" || echo "FAILED \$f"; done
\`\`\`

包里 \`selftest/src/\` 是源码副本（验收脚本按「脚本目录下的 src」找源码）。
\`p1\` 里那条"宿主连接"用例需要 \`build/uya-agent\`，包里没有会自动 SKIP。

验收脚本覆盖：协议、注册表、存储、Bible、Canon、LLM 传输、剧本、上下文、
任务、分镜、Provider、QA、审计、反例库、合成、端到端、索引、规模。

## 边界

- 模型是 mock（确定性、不联网）；真实 Provider 是替换点，未接。
- 视频是 mock 占位文件；真实产线 Adapter 与 FFmpeg 转码未接。
- 没有 fsync：掉电可能丢最后一次提交。
README

echo "== 打包 =="
TAR="$OUT/$PKG.tar.gz"
tar -czf "$TAR" -C "$OUT" "$PKG"
SUM=$(sha256sum "$TAR" | cut -d' ' -f1)
printf '%s  %s\n' "$SUM" "$(basename "$TAR")" > "$TAR.sha256"
echo "   $TAR"
echo "   sha256 $SUM"

echo "----"
echo "PASS: 交付包已生成（$PKG，$(ls "$STAGE/src" | wc -l) 个源文件）"
