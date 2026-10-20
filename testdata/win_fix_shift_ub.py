#!/usr/bin/env python3
"""testdata/win_fix_shift_ub.py — `make windows` 的第 2 步之一（只改生成物）。

**为什么需要它**：codegen 把 `u64` 常量拆成高低两半时，生成的是

    ((int64_t)(uint32_t)0xCBFAE6E4ULL << 32)

高半 >= 0x80000000 时，这是一个**有符号左移溢出** —— C 标准里是未定义行为。
宿主 GCC 默认不开 UBSan，所以这条缺陷在本机一直看不见；而 **zig cc（clang）默认开**
（`-fsanitize=undefined` 的 shift 检查），于是在 Windows 真机上**进程启动就 panic**：

    thread N panic: left shift of 3421674724 by 32 places cannot be represented
    in type 'int64_t' (aka 'long long')

实测现场：dockur/windows 的 Win10 客户机里跑不带参数的 `uya-agent.exe`（进全屏 TUI），
屏幕上一行 panic + 调用栈，退出后什么都看不到。

**修法**：把那个 `(int64_t)` 换成 `(uint64_t)`。移位在无符号域里完全定义良好，结果的
位模式与设计意图（高低两半拼成一个 u64）**逐字节相同** —— 这也能从「改了之后 TUI 正常
渲染、剪贴板/编码/按键用例全绿」反证。

**为什么修生成物而不是改 Uya 源码**：拆常量是 codegen 的行为，源码里写的就是一个普通
的 `u64` 字面量（`std/tls/crypto/sha384.uya` 的 K 表之类），没有任何可写的地方能绕开。
哪天编译器修好了，本脚本替换 0 处并退出 0，构建不受影响。

用法：
    python3 testdata/win_fix_shift_ub.py <生成的 .c>
"""

import re
import sys

# `((int64_t)(uint32_t)0x…ULL << 32)` —— HI 半部分常量
SHIFT_RE = re.compile(
    r'\(\(int64_t\)\(uint32_t\)(0x[0-9A-Fa-f]+ULL) << 32\)'
)


def fix(path):
    """把所有有符号左移溢出的常量拆半改写成无符号域。返回替换了几处。"""
    with open(path, encoding='utf-8', errors='replace') as fh:
        text = fh.read()
    fixed, n = SHIFT_RE.subn(r'((uint64_t)(uint32_t)\1 << 32)', text)
    if n:
        with open(path, 'w', encoding='utf-8', errors='replace') as fh:
            fh.write(fixed)
    return n


def main(argv):
    if len(argv) != 2:
        print('用法: win_fix_shift_ub.py <生成的 .c>', file=sys.stderr)
        return 2
    n = fix(argv[1])
    if n == 0:
        print('win_fix_shift_ub: 无需修补（生成物里没有有符号左移溢出）')
    else:
        print('win_fix_shift_ub: 已修 %d 处有符号左移溢出' % n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
