#!/bin/sh
# drama_plugin/proto/https_probe_selftest.sh
#
# 验收 P0_FINDINGS §1.10 / §1.12 的最终结论（v1.4 起）：
#   1) 默认配置（校验证书）握手成功、拿到 S: 200；
#   2) insecure 模式同样拿到 S: 200；
#   3) 默认配置不再出现「peer not verified」——证书链、主机名、信任锚都要过。
#
# 历史：v1.1 时这里断言的是「默认配置必然失败」。上游 5 个 bug 修完
# （ECDSA 公钥/验签、扩展解析、信任库截断、MPI limb 上限、裸 flight 捕获）
# 之后断言反过来了——这个脚本就是那条回归线。
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
    bad "默认配置仍在 peer not verified —— 证书校验没修好"
else
    ok "默认配置不再出现 peer not verified —— 证书校验真的过了"
fi
if echo "$verified" | grep -q 'S: 200'; then
    ok "默认配置（校验证书）拿到 200 —— 真实站点可验证访问"
else
    bad "默认配置没拿到 200（输出尾部：$(echo "$verified" | tail -3)）"
fi
if echo "$verified" | grep -q 'ERR https_get'; then
    bad "默认配置仍然报错：$(echo "$verified" | grep -m1 'ERR https_get')"
else
    ok "默认配置没有报错 —— 没有静默降级到 insecure"
fi
if echo "$insecure" | grep -q 'S: 200'; then
    ok "insecure 模式拿到 200 —— 说明传输层本身是通的"
else
    bad "insecure 模式没拿到 200（输出尾部：$(echo "$insecure" | tail -3)）"
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: HTTPS 客户端在默认校验模式下可用（结论可复现）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
