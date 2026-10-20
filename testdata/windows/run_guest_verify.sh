#!/bin/sh
# testdata/windows/run_guest_verify.sh — 在 dockur/windows 的 Win10 客户机里验
# `build/uya-agent.exe`（真控制台 / 真按键 / 真剪贴板）。
#
# 为什么不能在 Linux 上验完就算：三条路只有真机能证伪 ——
#   * 控制台中文编码（conhost 按代码页解释字节，重定向绕过它）；
#   * 按键翻译（ConPTY / 输入记录那一层，往管道写字节测不出）；
#   * 剪贴板（OpenClipboard 是会话级的，wine 与重定向都不等价）。
#
# 前置（由调用方负责）：
#   * `make windows` 已产出 build/uya-agent.exe；
#   * docker 容器 `win10`（dockur/windows）已起来且客户机可达；
#   * skill `uya-ssh-win10-verify` 的 helper 在
#     ~/.agents/skills/uya-ssh-win10-verify/scripts/win_guest.sh。
#
# 用法：
#   sh testdata/windows/run_guest_verify.sh            # 全量
#   sh testdata/windows/run_guest_verify.sh help clip  # 只跑指定用例
#
# 退出码 0 = 全过；1 = 有用例红（报告留在客户机共享目录的 w_*.txt 里）。
set -u

REPO=$(cd "$(dirname "$0")/../.." && pwd)
S="${WIN_GUEST_SH:-$HOME/.agents/skills/uya-ssh-win10-verify/scripts/win_guest.sh}"
EXE="$REPO/build/uya-agent.exe"
HERE="$REPO/testdata/windows"
ZIG="${ZIG:-$(command -v zig 2>/dev/null || echo /home/winger/zig-x86_64-linux-0.16.0/zig)}"

if [ ! -f "$EXE" ]; then
    echo "FAIL: 先 make windows（缺 $EXE）" >&2
    exit 1
fi
if [ ! -x "$S" ]; then
    echo "FAIL: 找不到 win_guest.sh（$S）" >&2
    exit 1
fi

echo "== 宿主准备：交叉编译 cap.exe / kbd.exe（真控制台取证工具）"
"$ZIG" cc -target x86_64-windows-gnu -std=c99 -O1 \
    "$HERE/cap.c" -o /tmp/cap.exe >/dev/null 2>&1 || {
    echo "FAIL: cap.c 编译失败" >&2; exit 1; }
"$ZIG" cc -target x86_64-windows-gnu -std=c99 -O1 \
    "$HERE/kbd.c" -o /tmp/kbd.exe >/dev/null 2>&1 || {
    echo "FAIL: kbd.c 编译失败" >&2; exit 1; }

echo "== 投递产物与工具"
sh "$S" put "$EXE" >/dev/null || exit 1
sh "$S" put /tmp/cap.exe >/dev/null || exit 1
sh "$S" put /tmp/kbd.exe >/dev/null || exit 1
sh "$S" put "$HERE/clipset.ps1" >/dev/null || exit 1
sh "$S" put "$HERE/clipimg.ps1" >/dev/null || exit 1

# 用例名 → 报告文件。报告是 cap/kbd 写的 UTF-8，宿主侧断言。
WANT="${*:-help ps tui demo clip img}"

fail=0
for c in $WANT; do
    bat="$HERE/case_$c.bat"
    rep="w_$c.txt"
    if [ ! -f "$bat" ]; then
        echo "SKIP: 没有 case_$c.bat"
        continue
    fi
    echo "== 用例 $c"
    sh "$S" run "$bat" >/dev/null 2>&1
    if ! sh "$S" wait case_done.txt 180 >/dev/null 2>&1; then
        echo "FAIL[$c] 用例没跑完（客户机看门狗 180s）"
        fail=1
        continue
    fi
    out=$(sh "$S" show "$rep" 2>/dev/null)
    if [ -z "$out" ]; then
        echo "FAIL[$c] 没有报告 $rep"
        fail=1
        continue
    fi
    # 通用判据：真控制台 + 跑完 + 退出码 0 + 中文控制台（936）
    echo "$out" | grep -q '^had_console=1' || { echo "FAIL[$c] 没拿到真控制台"; fail=1; }
    echo "$out" | grep -q '^done=1' || { echo "FAIL[$c] done=1 缺失"; fail=1; }
    echo "$out" | grep -q '^exit_code=0' || {
        echo "FAIL[$c] 退出码非 0：$(echo "$out" | grep '^exit_code=')"; fail=1; }
    # 中文 Windows 的运行时代码页必须是 936（65001 说明我们把控制台改了没还原）
    echo "$out" | grep -q '^console_output_cp_run=936' || {
        echo "FAIL[$c] 控制台代码页不是 936"; fail=1; }
    # 不许出现「UTF-8 被当 GBK 解」的典型乱码（鐢ㄦ硶 / 涓枃 一族）
    if echo "$out" | grep -qE '鐢ㄦ硶|涓枃|娴嬭瘯'; then
        echo "FAIL[$c] 屏幕上出现 UTF-8 被当 GBK 解的乱码"; fail=1
    fi
    # 各用例自己的断言
    case "$c" in
        help) echo "$out" | grep -q '极简 CLI 编程 agent' || {
                  echo "FAIL[$c] 屏幕里没有中文标题"; fail=1; } ;;
        ps)   echo "$out" | grep -q 'base_url = ' || {
                  echo "FAIL[$c] --print-config 没输出"; fail=1; } ;;
        clip) echo "$out" | grep -q 'CLIPWIN_PROBE_42 中文测试' || {
                  echo "FAIL[$c] 剪贴板文本没贴对（含中文）"; fail=1; } ;;
        img)  echo "$out" | grep -q 'image/jpeg' || {
                  echo "FAIL[$c] 剪贴板图片没贴上"; fail=1; } ;;
        demo) echo "$out" | grep -q 'Ask anything' || {
                  echo "FAIL[$c] TUI 快照没渲染出来"; fail=1; } ;;
    esac
    if [ "$fail" = "0" ]; then
        echo "PASS: $c"
    fi
done

if [ "$fail" = "0" ]; then
    echo "PASS: 客户机（win10）Windows 产物验证通过"
else
    echo "FAIL: 有断言没过，报告在客户机共享目录的 w_*.txt"
fi
exit "$fail"
