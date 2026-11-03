#!/bin/sh
# drama_plugin/proto/scan_selftest.sh
#
# P0 原型验收：目录枚举 + 文件摘要读回（百集索引的前置能力）。
# 断言的是可判定事实：条目数、空目录、摘要稳定性与区分度、1000 文件枚举成本。
#
# 用法：sh drama_plugin/proto/scan_selftest.sh

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

scan() {  # scan <命令文本...>：一个进程里跑多条命令
    printf '%s\nq\n' "$1" | timeout 300 "$UYA" run "$HERE/scan.ush"
}

# ---------- 1. 枚举：3 文件 + 1 子目录 ----------
mkdir -p "$TMP/d1/sub"
printf 'abc' > "$TMP/d1/a.txt"
printf 'zzz' > "$TMP/d1/b.txt"
printf 'yyy' > "$TMP/d1/c.txt"
out=$(scan "ls $TMP/d1")
echo "  ls -> $(echo "$out" | tr '\n' ' ')"
if echo "$out" | grep -q '^COUNT 4$'; then
    ok "枚举：4 个条目（3 文件 + 1 子目录）"
else
    bad "枚举：条目数不对（$out）"
fi
missing=""
for f in a.txt b.txt c.txt sub; do
    echo "$out" | grep -qx "NAME $f" || missing="$missing $f"
done
if [ -z "$missing" ]; then
    ok "枚举：文件名逐个出现（未漏、未串）"
else
    bad "枚举：缺少条目$missing"
fi
if echo "$out" | grep -q '^NAME \.'; then
    bad "枚举：把 . 或 .. 也列出来了"
else
    ok "枚举：跳过 . 与 .."
fi

# ---------- 2. 空目录 ----------
mkdir -p "$TMP/empty"
out=$(scan "ls $TMP/empty")
if echo "$out" | grep -q '^COUNT 0$'; then
    ok "空目录：COUNT 0（不报错）"
else
    bad "空目录：输出不对（$out）"
fi

# ---------- 3. 摘要：稳定 + 有区分度 + 空文件已知值 ----------
printf 'abc' > "$TMP/same1.txt"
printf 'abc' > "$TMP/same2.txt"
printf 'abd' > "$TMP/diff.txt"
: > "$TMP/empty.txt"
out=$(scan "sum $TMP/same1.txt
sum $TMP/same2.txt
sum $TMP/diff.txt
sum $TMP/empty.txt")
sum1=$(echo "$out" | sed -n '2p' | sed 's/^SUM //')
sum2=$(echo "$out" | sed -n '4p' | sed 's/^SUM //')
sum3=$(echo "$out" | sed -n '6p' | sed 's/^SUM //')
sum0=$(echo "$out" | sed -n '8p' | sed 's/^SUM //')
echo "  sums: $sum1 $sum2 $sum3 $sum0"
if [ "$sum1" = "$sum2" ]; then
    ok "摘要：同内容同摘要（可比较）"
else
    bad "摘要：同内容摘要不同（$sum1 vs $sum2）"
fi
if [ "$sum1" != "$sum3" ]; then
    ok "摘要：一字之差摘要不同（有区分度）"
else
    bad "摘要：不同内容摘要相同（碰撞）"
fi
if [ "$sum0" = "cbf29ce484222325" ]; then
    ok "摘要：空文件 = FNV-1a 64 偏移基值（实现正确）"
else
    bad "摘要：空文件摘要 $sum0，与 FNV-1a 64 基值不符"
fi
if echo "$out" | grep -q '^SIZE 3$'; then
    ok "摘要：同时报出文件大小"
else
    bad "摘要：没报文件大小（$out）"
fi

# ---------- 4. 1000 文件枚举成本 ----------
mkdir -p "$TMP/many"
i=0
while [ "$i" -lt 1000 ]; do
    : > "$TMP/many/f$i.dat"
    i=$((i + 1))
done
start=$(date +%s)
out=$(scan "ls $TMP/many")
end=$(date +%s)
elapsed=$((end - start))
if echo "$out" | grep -q '^COUNT 1000$'; then
    ok "1000 文件：枚举完整（COUNT 1000）"
else
    bad "1000 文件：条目数不对（$(echo "$out" | tail -1)）"
fi
# 这个时间含 uya 编译，所以只作为量级参考；< 60 s 说明没有 O(n²) 之类的坑。
if [ "$elapsed" -lt 60 ]; then
    ok "1000 文件：整轮墙钟 ${elapsed}s（含编译；量级正常）"
else
    bad "1000 文件：整轮墙钟 ${elapsed}s，超出预期"
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: 目录枚举 + 摘要（百集索引前置能力）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
