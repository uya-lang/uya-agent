#!/bin/sh
# 用途：作为 Uya 的 CC_DRIVER 使用，包装 zig cc 以便交叉编译 macOS 目标。
#
# 三件事，都在**生成物**上做，源码与编译器一字不动，然后把参数原样交给 zig cc：
#
# ① Mach-O 的下划线前缀。uya 生成的头文件 uya_part1_types.h 里，libc 桥接符号写成
#    __asm__("write")，这会绕过 Mach-O 的自动下划线前缀，链接时找不到 _write。
#    只碰 uya_host_ / uya_macos_real_ 那几行，__asm__("r10") 这类寄存器名不受影响。
#    幂等：改过的行不再匹配。
#
# ② 有符号左移溢出。codegen 把 u64 常量拆成高低两半时写的是
#    ((int64_t)(uint32_t)0x…ULL << 32) —— 高半 >= 0x80000000 就是 UB。
#    宿主 GCC 默认不开 UBSan 看不见，而 **zig cc（clang）在 -O0 默认开**
#    （-fsanitize=undefined 的 shift 检查），于是 macOS 上跑到 tui_mq_key 就 panic：
#      thread N panic: left shift of 3421674724 by 32 places cannot be represented
#    Windows 构建早就踩过同一条（见 testdata/win_fix_shift_ub.py），这里复用同一个
#    修补脚本，按「即将编译的那个 .c」逐个修。
#
# ③ Darwin SDK 与生成物自带的同名 tag 撞车（timeval / sigaction / stat …）。
#    见 testdata/macos/fix_darwin_headers.py 的说明；那里按「整份生成物」一次处理。
#
# 用法：CC_DRIVER="$PWD/testdata/macos/zig-darwin-cc.sh" TARGET_TRIPLE=x86_64-macos …
set -e

: "${ZIG:=/home/winger/zig-x86_64-linux-0.16.0/zig}"

# 本脚本所在目录 → 仓库根（testdata/macos/..）
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

# 从「这次要编译的 .c」往上找含 uya_part1_types.h 的目录 = 多文件 C 的缓存根。
# 链接步没有 .c（也就不用修），找不到就什么都不做。
CACHE=
for arg in "$@"; do
    case "$arg" in
    *.c)
        [ -f "$arg" ] || continue
        dir=$(dirname -- "$arg")
        i=0
        while [ "$i" -lt 4 ]; do
            if [ -f "$dir/uya_part1_types.h" ]; then
                CACHE=$dir
                break
            fi
            dir=$dir/..
            i=$((i + 1))
        done
        [ -n "$CACHE" ] && break
        ;;
    esac
done

if [ -n "$CACHE" ]; then
    # ① 符号前缀
    sed -i -E \
        '/uya_host_|uya_macos_real_/ s/__asm__\("([a-z][a-z_0-9]*)"\)/__asm__("_\1")/' \
        "$CACHE/uya_part1_types.h"
    # ③ 同名 tag 避让（整份生成物一次）。
    # 用头文件里的标记判断「这次生成的产物是否已经补过」——每次 uya build 都会重新
    # 生成整份产物，所以不能靠哨兵文件，否则第二次构建会跳过修补。
    if ! grep -q UYA_DARWIN_HOST_RENAME "$CACHE/uya_part1_types.h"; then
        python3 "$ROOT/testdata/macos/fix_darwin_headers.py" "$CACHE" >/dev/null
    fi
    # ② 本次的 .c 里的常量拆半左移（只认编译步：argv 里有 -c 才动手）
    is_compile=0
    for arg in "$@"; do
        [ "$arg" = "-c" ] && is_compile=1
    done
    if [ "$is_compile" = "1" ]; then
        for arg in "$@"; do
            case "$arg" in
            *.c)
                [ -f "$arg" ] && \
                    python3 "$ROOT/testdata/win_fix_shift_ub.py" "$arg" >/dev/null
                ;;
            esac
        done
    fi
fi

exec "$ZIG" cc "$@"
