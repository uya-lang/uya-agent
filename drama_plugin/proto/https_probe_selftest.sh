#!/bin/sh
# drama_plugin/proto/https_probe_selftest.sh
#
# 复现 P0_FINDINGS §1.10 的两条结论：
#   1) 默认配置（校验证书）握手失败：peer not verified；
#   2) insecure 模式握手成功、拿到 S: 200。
#
# 这一步**需要联网**（DNS + 443 出网）。没网时脚本打印 SKIP 并以 0 退出，
# 不把环境问题当成代码问题。
#
# 用法：sh drama_plugin/proto/https_probe_selftest.sh

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

"$UYA" build "$HERE/https_probe.uya" -o "$TMP/probe" >"$TMP/build.log" 2>&1 || {
    echo "FAIL: 编译失败"
    tail -5 "$TMP/build.log"
    exit 1
}

clean() { tr -d '\000'; }

verified=$("$TMP/probe" 2>&1 | clean || true)
insecure=$(timeout 60 "$TMP/probe" insecure 2>&1 | clean || true)

if ! echo "$insecure" | grep -q 'DNS resolved'; then
    echo "SKIP: 域名解析不可用（离线环境），本次不判定 HTTPS 结论"
    exit 0
fi

fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

if echo "$verified" | grep -q 'peer not verified'; then
    ok "默认配置（校验证书）握手失败在 peer not verified —— 与文档一致"
else
    bad "默认配置没有出现 peer not verified（证书校验可能已实现，需更新文档）"
fi
if echo "$verified" | grep -q 'ERR https_get'; then
    ok "默认配置下 https_get 返回错误（不会静默降级）"
else
    bad "默认配置下 https_get 没有报错"
fi
if echo "$insecure" | grep -q 'S: 200'; then
    ok "insecure 模式拿到 200 —— 说明传输层本身是通的"
else
    bad "insecure 模式没拿到 200（输出尾部：$(echo "$insecure" | tail -3)）"
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: HTTPS 客户端存在、证书校验未完成（结论可复现）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
