#!/bin/sh
# drama_plugin/proto/txn_selftest.sh
#
# P0 B3 的验收脚本：文件事务 + 锁 + 陈旧锁 + 崩溃窗口。
# 只断言可判定的事实（文件在不在、大小对不对、锁状态字样），不看日志措辞。
#
# 用法：sh drama_plugin/proto/txn_selftest.sh

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "workdir: $TMP"

fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

run_cmd() {  # run_cmd <命令文本>：起一个进程、喂一条命令、等它退出
    printf '%s\nq\n' "$1" | timeout 120 "$UYA" run "$HERE/txn.ush"
}

# `uya run` 会编译后再起子进程：只杀包装进程时子进程还活着，会把 .tmp 提交掉。
# 所以常驻实例用 setsid 起，杀的时候按进程组杀，并等到进程真的没了。
start_server() {
    _name=$1
    mkfifo "$TMP/$_name.in"
    if command -v setsid >/dev/null 2>&1; then
        setsid "$UYA" run "$HERE/txn.ush" \
            < "$TMP/$_name.in" > "$TMP/$_name.out" 2>&1 &
    else
        "$UYA" run "$HERE/txn.ush" \
            < "$TMP/$_name.in" > "$TMP/$_name.out" 2>&1 &
    fi
    eval "pid_$_name=\$!"
}

kill_hard() {
    _name=$1
    eval "_p=\$pid_$_name"
    kill -9 "-$_p" 2>/dev/null || kill -9 "$_p" 2>/dev/null || true
    _i=0
    while pgrep -f "$HERE/txn.ush" >/dev/null 2>&1 && [ "$_i" -lt 50 ]; do
        sleep 0.1
        _i=$((_i + 1))
    done
    wait "$_p" 2>/dev/null || true
}

# ---------- 1. 原子写：内容完整、大小正确 ----------
out=$(run_cmd "w $TMP/a.bin 1000")
[ "$out" = "WROTE" ] || bad "原子写没有回 WROTE：$out"
if [ -f "$TMP/a.bin" ] && [ "$(wc -c < "$TMP/a.bin")" -eq 1000 ]; then
    ok "原子写：目标文件存在且大小 = 1000 字节"
else
    bad "原子写：目标文件缺失或大小不对"
fi
[ -f "$TMP/a.bin.tmp" ] && bad "原子写后仍留下 .tmp" || ok "原子写后没有残留 .tmp"

# ---------- 2. 锁互斥：活进程占着 → BUSY ----------
start_server one
exec 3> "$TMP/one.in"
echo "l $TMP/guard.lock" >&3
sleep 2
# 第二个进程（走另一个 fifo）抢同一把锁
start_server two
exec 4> "$TMP/two.in"
echo "l $TMP/guard.lock" >&4
echo "q" >&4
exec 4>&-
wait "$pid_two" 2>/dev/null || true
if grep -q '^ACQUIRED' "$TMP/one.out"; then
    ok "第一个进程抢到锁：$(cat "$TMP/one.out")"
else
    bad "第一个进程没抢到锁：$(cat "$TMP/one.out")"
fi
if grep -q '^BUSY' "$TMP/two.out"; then
    ok "第二个进程被活锁挡住：$(cat "$TMP/two.out")"
else
    bad "第二个进程没有被挡住：$(cat "$TMP/two.out")"
fi

# ---------- 3. 陈旧锁：kill -9 持有者后能回收 ----------
kill_hard one
exec 3>&-
out=$(run_cmd "l $TMP/guard.lock")
case "$out" in
    STALE-RECOVERED*) ok "陈旧锁被识别并回收：$out" ;;
    *) bad "陈旧锁没被回收：$out" ;;
esac

# ---------- 4. 崩溃窗口：数据写完、rename 之前被 kill -9 ----------
# 用 `wp`（write-then-pause）：它把数据写进 .tmp 后打印 READY 并阻塞，
# 脚本此时 kill -9，正好落在「数据已落盘、目标文件还没出现」的窗口。
BIG="$TMP/big.bin"
start_server three
exec 5> "$TMP/three.in"
echo "wp $BIG 1048576" >&5
i=0
while ! grep -q '^READY' "$TMP/three.out" 2>/dev/null && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
done
if ! grep -q '^READY' "$TMP/three.out" 2>/dev/null; then
    bad "崩溃测试：没等到 READY（输出：$(cat "$TMP/three.out")）"
else
    # 顺序要紧：先杀干净（进程组），再关 fifo。
    # 反过来的话，关 fifo 会让阻塞中的 read 返回 EOF，进程反而把 tmp 提交了。
    kill_hard three
    exec 5>&-
    if [ -f "$BIG" ]; then
        bad "崩溃后目标文件存在：$(wc -c < "$BIG") 字节"
    else
        ok "崩溃后目标文件不存在（数据只在 .tmp 里）⇒ 不会出现半个文件"
    fi
    if [ -f "$BIG.tmp" ]; then
        ok "崩溃后残留 .tmp（可被孤儿清理回收）：$(wc -c < "$BIG.tmp") 字节"
    else
        bad "崩溃后连 .tmp 都没有，无法证明窗口位置"
    fi
fi

# ---------- 5. 崩溃后重试：同名目标可以由下一次事务写成功 ----------
rm -f "$BIG.tmp"
out=$(run_cmd "w $BIG 200000")
if [ "$out" = "WROTE" ] && [ "$(wc -c < "$BIG")" -eq 200000 ]; then
    ok "崩溃后重试成功：目标文件大小 = 200000"
else
    bad "崩溃后重试失败：$out"
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: B3（原子写 / 锁互斥 / 陈旧锁回收 / 崩溃不留半个文件）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
