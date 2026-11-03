#!/bin/sh
# drama_plugin/proto/worker_selftest.sh
#
# P0 验收：Worker 中断/重启语义 —— 杀进程后从检查点继续，
# 已完成的步骤不被重复执行（DESIGN §9.3 的核心断言）。
#
# 用法：sh drama_plugin/proto/worker_selftest.sh

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

run_all() {  # run_all <dir> <steps>
    printf 'run %s %s\nq\n' "$1" "$2" | timeout 300 "$UYA" run "$HERE/worker.ush"
}

# ---------- 1. 一次跑完 ----------
mkdir -p "$TMP/w1"
out=$(run_all "$TMP/w1" 3)
echo "  run 3 -> $(echo "$out" | tr '\n' ' ')"
if echo "$out" | grep -q '^RESUME 1$'; then
    ok "首次运行：RESUME 1（没有历史就从第 1 步开始）"
else
    bad "首次运行：RESUME 不是 1（$out）"
fi
if [ "$(grep -c '^done ' "$TMP/w1/journal.log" 2>/dev/null || echo 0)" -eq 3 ]; then
    ok "首次运行：journal 有 3 条 done"
else
    bad "首次运行：journal 条数不对"
fi

# ---------- 2. 中途杀进程 ----------
mkdir -p "$TMP/w2"
mkfifo "$TMP/w2.in"
if command -v setsid >/dev/null 2>&1; then
    setsid "$UYA" run "$HERE/worker.ush" \
        < "$TMP/w2.in" > "$TMP/w2.out" 2>&1 &
else
    "$UYA" run "$HERE/worker.ush" \
        < "$TMP/w2.in" > "$TMP/w2.out" 2>&1 &
fi
wpid=$!
exec 5> "$TMP/w2.in"
echo "run $TMP/w2 10" >&5
i=0
while ! grep -q '^STEP 4$' "$TMP/w2.out" 2>/dev/null && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
done
if ! grep -q '^STEP 4$' "$TMP/w2.out" 2>/dev/null; then
    bad "中途杀进程：没等到 STEP 4（输出：$(cat "$TMP/w2.out" | tr '\n' ' ')）"
else
    # 先杀干净（进程组），再关 fifo：反过来会让阻塞的 read 走 EOF 正常退出
    kill -9 "-$wpid" 2>/dev/null || kill -9 "$wpid" 2>/dev/null || true
    i=0
    while pgrep -f "$HERE/worker.ush" >/dev/null 2>&1 && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    wait "$wpid" 2>/dev/null || true
    exec 5>&-
    ok "中途杀进程：在 STEP 4 之后硬杀"
fi

done_before=$(grep -c '^done ' "$TMP/w2/journal.log" 2>/dev/null || echo 0)
echo "  被杀时已完成: $done_before 步"

# ---------- 3. 重启后从检查点继续 ----------
out=$(run_all "$TMP/w2" 10)
resume=$(echo "$out" | sed -n 's/^RESUME //p')
echo "  重启 -> RESUME $resume / $(echo "$out" | tail -1)"
if [ -n "$resume" ] && [ "$resume" -gt 1 ]; then
    ok "重启：从第 $resume 步继续（没有从 1 重跑）"
else
    bad "重启：RESUME 不对（$out）"
fi
if [ -n "$resume" ] && [ "$resume" -le "$((done_before + 1))" ]; then
    ok "重启：起点不超过「已完成 + 1」（没有跳步，也没有重做）"
else
    bad "重启：起点 $resume 与已完成 $done_before 不符"
fi
if echo "$out" | grep -q '^FINAL 10$'; then
    ok "重启：跑完剩余步骤（FINAL 10）"
else
    bad "重启：没有跑到 FINAL 10（$out）"
fi

# ---------- 4. 每步恰好一次 ----------
total=$(grep -c '^done ' "$TMP/w2/journal.log" 2>/dev/null || echo 0)
uniq=$(sed 's/^done //' "$TMP/w2/journal.log" | sort -n | uniq | wc -l)
if [ "$total" -eq 10 ] && [ "$uniq" -eq 10 ]; then
    ok "journal：10 条 done、10 个不同步骤 ⇒ 每步恰好执行一次"
else
    bad "journal：条数 $total、不同步骤 $uniq（应为 10/10，重复即违约）"
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: Worker 中断/重启（检查点续跑、不重复执行）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
