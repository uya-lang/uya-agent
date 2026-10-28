#!/bin/sh
# 用途：跑一次 `uya build`，撞上「生成的 `.c` 内容坏了」就把缓存清掉重来。
#
# 为什么需要：随仓发出去的编译器（`uya/bin/uya-real`，v0.10.4 预编译）写 split-C
# 时**偶尔写出坏文件**，症状是编译期报一屏「行号/列号离谱」的语法错。GitHub
# Actions 上稳定复现的那次（run #3 的注解）：
#
#     src/diff/model.c:819:10: error: expected ')'
#     src/diff/model.c:818:53: error: expected identifier
#     src/diff/model.c:817:42: error: expected function body after function declarator
#
# 而同一份源码在开发机上生成的同名文件只有 799 行（本地对照），且开发机上也偶发
# （`/home` 只剩十几 GB 时见过两次：一次 `search.c` 尾巴停在 `/* defer */`，
# 一次 `session.c` 同一行被写到 18000 列）。成因没查清（像是单次 write() 短写没补写），
# 但只要**重新生成一遍**就好了 —— 这条脚本把「清缓存 + 重跑」自动化，最多 N 次。
#
# 为什么整目录清、而不是只删那几个文件：删单个 `.c` 会让链接步少掉一个 `.o`
# （实测撞出 `undefined symbol: _main` 那种更难看的失败）。整目录清最多多花一次
# 全量编译，换来一个干净状态。
#
# 只认**那一种形状**才重试：日志里出现 `<路径>.c:<行>:<列>: error:`。别的失败
# （链接错、找不到编译器、真正的语法错误）一律原样退出，绝不吞掉。
#
# 用法：uya_build_retry.sh <cache 目录> <日志文件> <最多尝试次数> -- <构建命令…>
#   cache 目录：编译器写 split-C 的地方（Linux 是 build/uyacache，macOS 是
#               build/macos/uyacache-<arch>）。日志里的相对路径就是相对它。
# 输出：命令的输出**照旧实时打屏**（同时 tee 到日志文件），make 的观感不变。
#       第 1 次尝试的失败日志另存为 <日志>.first，方便事后看坏在哪。
set -u

usage() {
    echo "用法: $0 <cache 目录> <日志文件> <最多尝试次数> -- <构建命令…>" >&2
    exit 2
}

[ $# -ge 5 ] || usage
cache=$1
log=$2
tries=$3
shift 3
[ "${1:-}" = "--" ] && shift
[ $# -ge 1 ] || usage

# 这个脚本会 `rm -rf` 缓存目录，先把「不可能是有意的」挡掉。
case "$cache" in
"" | / | . | ..)
    echo "uya_build_retry: cache 目录取值不安全（'$cache'），拒绝执行" >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname -- "$log")"
rm -f "$log"

n=1
while [ "$n" -le "$tries" ]; do
    # 命令的输出走 tee 保持实时；退出码借一个临时文件带出管道。
    { "$@" 2>&1; echo $? > "$log.rc"; } | tee "$log"
    rc=$(cat "$log.rc" 2>/dev/null || echo 1)
    rm -f "$log.rc"
    if [ "$rc" -eq 0 ]; then
        if [ "$n" -gt 1 ]; then
            echo "uya_build_retry: 第 $n 次尝试通过（前 $((n - 1)) 次生成的 .c 是坏的）"
        fi
        exit 0
    fi
    if [ "$n" = "1" ]; then
        cp -f "$log" "$log.first" 2>/dev/null || true
    fi
    bad=$(grep -oE '^[^ :]+\.c:[0-9]+:[0-9]+: error:' "$log" 2>/dev/null \
        | sed -e 's/:[0-9][0-9]*:.*//' \
        | sort -u)
    if [ -z "$bad" ]; then
        echo "uya_build_retry: 失败形状不是「生成的 .c 坏了」" \
            "（日志里没有 <文件>.c:<行>:<列>: error:），不重试" >&2
        exit "$rc"
    fi
    echo "uya_build_retry: 第 $n 次尝试失败，坏文件（顺手把证据留在日志里）：" >&2
    for f in $bad; do
        case "$f" in
        /*) p=$f ;;
        *) p=$cache/$f ;;
        esac
        if [ -f "$p" ]; then
            lines=$(wc -l < "$p")
            echo "  - $p（$lines 行，末尾 2 行：）" >&2
            tail -2 "$p" | sed -e 's/^/      /' >&2
        else
            echo "  - $p（文件不在：编译时它可能已经被删了）" >&2
        fi
    done
    echo "uya_build_retry: 清掉缓存 $cache 后重来" >&2
    rm -rf "$cache"
    n=$((n + 1))
done

echo "uya_build_retry: 试了 $tries 次还是失败（日志 $log）" >&2
exit 1
