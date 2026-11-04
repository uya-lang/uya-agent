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
# 注意：包里不含 Uya 工具链；构建和源码自测需要 Uya 0.11.0 与匹配标准库。

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}
OUT=${1:-$ROOT/dist}

VERSION=$(grep -o '"0\.[0-9]*\.[0-9]*"' "$HERE/src/main.uya" | head -1 | tr -d '"')
[ -n "$VERSION" ] || VERSION=0.0.0
PKG="drama-$VERSION"

mkdir -p "$OUT"
STAGE="$OUT/$PKG"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/docs" "$STAGE/src" "$STAGE/selftest"

echo "== 编译 =="
UYA="$UYA" UYA_ROOT="$UYA_ROOT" sh "$HERE/build.sh" "$STAGE/bin/drama"

echo "== 收集文件 =="
cp "$HERE"/docs/*.md "$STAGE/docs/"
cp "$HERE"/src/*.uya "$STAGE/src/"
cp "$HERE"/*_selftest.sh "$STAGE/selftest/"
cp "$HERE/build.sh" "$STAGE/build.sh"
cp -r "$HERE/proto" "$STAGE/selftest/proto"
# 验收脚本按「脚本目录下的 src/」找源码，包里就照这个布局放一份
cp -r "$HERE/src" "$STAGE/selftest/src"
rm -f "$STAGE"/selftest/proto/*.log 2>/dev/null || true

cat > "$STAGE/README.md" <<README
# drama $VERSION

短剧生产插件的可交付包。**不含 Uya 工具链**。
构建和源码自测需要 Uya 0.11.0；已构建的 \`bin/drama\` 可独立运行。
（本仓 \`uya/bin/uya\` + \`uya/stdlib\`）。

## 怎么构建

如需从源码构建或运行源码自测，需要 Uya 0.11.0 与匹配的标准库：

\`\`\`sh
UYA=/opt/uya/bin/uya UYA_ROOT=/opt/uya/stdlib \\
  sh build.sh build/drama
\`\`\`

## 怎么跑

\`\`\`sh
./bin/drama version
./bin/drama health --data-dir /tmp/drama-data
./bin/drama mcp serve --data-dir /var/lib/drama
./bin/drama worker run --data-dir /var/lib/drama
\`\`\`

MCP Server 与 Worker 是独立进程，必须在同一台机器共享同一个数据目录。
两条命令分别由 MCP Host 和服务管理器启动；Worker 单次扫描所有未完成任务后退出，
需再次启动才能处理后续任务。

## 数据备份与恢复

备份前先停止 MCP Host 和 Worker，确认没有进程写入数据目录。以数据根
`/var/lib/drama` 为例：

\`\`\`sh
DATA=/var/lib/drama
BACKUP=/var/backups/drama-\$(date +%F-%H%M%S).tar.gz
umask 077
mkdir -p "\$(dirname "\$BACKUP")"
tar -czf "\$BACKUP" -C "\$(dirname "\$DATA")" "\$(basename "\$DATA")"
\`\`\`

恢复时先解压到新目录，不覆盖原数据：

\`\`\`sh
RESTORE_PARENT=\$(mktemp -d)
tar -xzf "\$BACKUP" -C "\$RESTORE_PARENT"
RESTORE="\$RESTORE_PARENT/\$(basename "\$DATA")"
./bin/drama health --data-dir "\$RESTORE"
cat <<'JSON' | ./bin/drama mcp serve --data-dir "\$RESTORE"
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "call",
    "arguments": {"operation": "project.list", "input": {}}
  }
}
JSON
\`\`\`

确认 \`project.list\` 返回预期项目后，再由 MCP Host 和 Worker 切换到恢复目录。
备份包含整个数据根（项目、Canon、任务和资产）；不要只复制 \`canon.json\`。
本版本没有格式迁移，跨版本恢复前须先确认数据兼容性；无 fsync，异常断电
仍可能丢失最后一次写入。

## 怎么验

\`\`\`sh
UYA=<uya 编译器路径> UYA_ROOT=<标准库路径> \\
  sh selftest/build_selftest.sh
# 或跑完整 MCP 回归：
for f in selftest/p*_selftest.sh; do bash "\$f" || echo "FAILED \$f"; done
\`\`\`

包里 \`selftest/src/\` 是源码副本（验收脚本按「脚本目录下的 src」找源码）。
\`p1\` 里那条"宿主连接"用例需要 \`build/uya-agent\`，包里没有会自动 SKIP。

验收脚本覆盖：协议、注册表、存储、Bible、Canon、LLM 传输、剧本、上下文、
任务、分镜、Provider、QA、审计、反例库、合成、端到端、索引、规模。

## 边界

- 模型是 mock（确定性、不联网）；真实 Provider 是替换点，未接。
- 视频是 mock 占位文件；真实产线 Adapter 与 FFmpeg 转码未接。
- 没有 fsync：掉电可能丢最后一次提交。
- CLI version: $VERSION; Uya build tool: 0.11.0. The CLI version and data
  \`format_version\` are separate. Current project format is 1; no migration is
  provided, and 0.x releases make no cross-version data compatibility promise.
  Back up data and do not upgrade existing project data across releases yet.
- Config files are not loaded by the current CLI; use --data-dir.
- OpenAI-compatible requests currently send no Authorization/API Key header.
  Use only an unauthenticated endpoint you control; public authenticated
  providers are unsupported.
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
