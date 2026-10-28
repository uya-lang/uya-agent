#!/bin/sh
# testdata/macos/guest-run.sh — 客户机（macOS）侧跑自测并回收日志。
#
# 用法（在 macOS 里、在**可写目录**下）：
#   sh guest-run.sh                 # 默认：version goal tasks ws web mcp tui
#   sh guest-run.sh goal tasks      # 只跑这几组
#   sh guest-run.sh full            # 不加分流变量的整轮 --selftest
#
# 为什么要有这个脚本：VNC 里手敲长命令行容易错位，而 macOS 上跑 TUI 那一组
# 会把控制台会话带走（见 README §4），敲了一半的命令就再没机会补。这里从
# hub 下载二进制、逐组跑、**边跑边传**日志：会话没了也能从 hub 上看到它跑到
# 哪一轮、最后一行是什么。
#
# 组名 = 自测的单跑分流（`UYA_SELFTEST_<大写>_ONLY`），外加 version / help /
# full 三个特例。tui 与 full 会让 macOS 客户机的控制台会话整个重启，所以默认
# 排在最后，且 full 只在显式点名时才跑。
#
# 环境变量：
#   HUB     上传/下载用的 hub（默认 http://172.30.0.1:8099）
#   BIN     客户机上的二进制路径（默认 /tmp/uya-agent-macos）
#   WORK    工作根（默认 /tmp/ua-selftest，**自测要求 cwd 可写**）
#   PREFIX  上传文件名前缀（默认 m）
#   TTY=1   用 script(1) 给子进程套一层 pty（行缓冲）。stdout 落文件时是块缓冲，
#           段错误一来最后几 KB 就没了 —— 而「崩在哪一轮」恰恰就在那几 KB 里。

HUB=${HUB:-http://172.30.0.1:8099}
BIN=${BIN:-/tmp/uya-agent-macos}
WORK=${WORK:-/tmp/ua-selftest}
PREFIX=${PREFIX:-m}
RUNLOG=$WORK/$PREFIX-run.log

# 认得的组名。不在名单里就直接拒绝 —— 否则打错的组名会被当成「没设分流
# 变量」而跑整轮（包含 tui），把会话带走。
KNOWN="version help full title diff async perm tasks ws prune empty retry
goal model sess tui shell notify webchild web panel pm mcp proxy dns clip
img tls"

say() {
    echo "guest-run: $*"
    echo "guest-run: $*" >>"$RUNLOG"
}

up() {
    curl -s -T "$1" "$HUB/$2" >/dev/null 2>&1
}

known() {
    for k in $KNOWN; do
        [ "$k" = "$1" ] && return 0
    done
    return 1
}

# 下载二进制（已经存在就跳过）、补执行位、记下主机事实。
prepare() {
    mkdir -p "$WORK" || return 1
    cd "$WORK" || return 1
    : >"$RUNLOG"
    {
        echo "== 主机"
        uname -a
        sw_vers 2>/dev/null
        sysctl -n hw.model machdep.cpu.brand_string 2>/dev/null
    } >>"$RUNLOG" 2>&1
    if [ ! -x "$BIN" ]; then
        say "下载 $BIN"
        curl -sf -o "$BIN" "$HUB/uya-agent-macos" || return 1
        chmod +x "$BIN" || return 1
    fi
    ls -l "$BIN" >>"$RUNLOG" 2>&1
    "$BIN" --version >>"$RUNLOG" 2>&1
    say "二进制就绪"
    return 0
}

# 跑一组：日志先落文件，跑的过程中每 5 秒把当前日志传一次（心跳 + 中断留证）。
run_case() {
    name=$1
    shift
    log=$WORK/$PREFIX-$name.log
    say "开始 $name：$*"
    : >"$log"
    if [ "${TTY:-0}" = 1 ]; then
        ( script -q /dev/null "$@" ) >"$log" 2>&1 &
    else
        ( "$@" ) >"$log" 2>&1 &
    fi
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        up "$log" "$PREFIX-$name.partial.log"
    done
    wait "$pid"
    rc=$?
    echo "rc=$rc" >>"$log"
    up "$log" "$PREFIX-$name.log"
    say "结束 $name rc=$rc"
    return $rc
}

case_() {
    name=$1
    case $name in
    version | help)
        run_case "$name" "$BIN" "--$name"
        ;;
    full)
        run_case full "$BIN" --selftest
        ;;
    *)
        var=$(echo "$name" | tr 'a-z' 'A-Z')
        run_case "$name" env "UYA_SELFTEST_${var}_ONLY=1" \
            "$BIN" --selftest
        ;;
    esac
}

prepare || {
    say "准备失败（hub 不通或磁盘不可写）"
    up "$RUNLOG" "$PREFIX-run.log"
    exit 1
}

if [ $# -eq 0 ]; then
    set -- version goal tasks ws web mcp tui
fi

for want in "$@"; do
    if ! known "$want"; then
        say "未知组：$want（可用：$KNOWN）"
        continue
    fi
    case_ "$want"
    up "$RUNLOG" "$PREFIX-run.log"
done

say "全部跑完"
up "$RUNLOG" "$PREFIX-run.log"

# 在客户机里自测挂住时会话就没了，最后一行日志就是判据：
#   grep -c '^rc=0' 上传回来的 $PREFIX-*.log
