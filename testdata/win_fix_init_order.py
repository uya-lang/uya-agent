#!/usr/bin/env python3
"""testdata/win_fix_init_order.py — `make windows` 的第 2 步（只改生成物）。

**为什么需要它**：编译器发到单 TU 里的全局初始化器里，有一个接口值排在它要装箱的
具体 struct **之前**：

    struct uya_interface_RtFrame g_rtio_abort_frame_i = { .data = (void*)&(g_rtio_abort_frame) };
    struct RtioAbortFrame   g_rtio_abort_frame       = { .hits = 0 };

C 里「用还没声明的对象取地址」是硬错误，clang（zig cc 的内核）直接报
`use of undeclared identifier 'g_rtio_abort_frame'`。宿主 GCC 也编不过 —— 这条只在
**单 TU**（`--no-split-c`）下出现，而 Windows 必须走单 TU（见 Makefile 里
`make windows` 那段注释：split-C 会把 Win32 桥的定义发进每一个 .c，链接期 duplicate
symbol）。

**为什么修生成物而不是改 Uya 源码**：语序由编译器按声明顺序发射，源码里两个全局的
**声明顺序本来是对的**（`g_rtio_abort_frame` 先、接口值后，见
`src/selftest/st_async_io.uya`）；是 codegen 把接口值的初始化器提前了。改源码绕不过
去（换个位置还会再撞），而这条脚本把「交换这两行」写成可复跑的判据 —— 哪天编译器
修好了，脚本会打印「无需修补」并退出 0，构建不受影响。

用法：
    python3 testdata/win_fix_init_order.py <生成的 .c>
"""

import re
import sys

# 接口值：`struct uya_interface_X <name> = (struct uya_interface_X){ .vtable = …,
# .data = (void*)&(<TGT>) };` —— 整行，行尾的 `\n` 由调用方按行切分后不再存在。
IFACE_RE = re.compile(
    r'^__attribute__\(\(used\)\) struct uya_interface_\w+ (\w+) = '
    r'\(struct uya_interface_\w+\)\{.*\.data = \(void\*\)&\((\w+)\) \};$'
)
# 具体 struct 的零初始化定义（`{...}` 或 `{ .hits = 0 }` 都算）
DEF_RE = re.compile(
    r'^__attribute__\(\(used\)\) struct (\w+) (\w+) = '
)


def fix(path):
    """把「接口值在目标 struct 之前」的那些对调。返回修了几处。"""
    with open(path, encoding='utf-8', errors='replace') as fh:
        lines = fh.read().split('\n')

    # 每个具体 struct 名字 → 定义行号
    def_line = {}
    for i, line in enumerate(lines):
        m = DEF_RE.match(line)
        if m:
            def_line[m.group(2)] = i

    # 找出所有「先引用、后定义」的接口值
    swaps = []
    for i, line in enumerate(lines):
        m = IFACE_RE.match(line)
        if not m:
            continue
        target = m.group(2)
        if target in def_line and def_line[target] > i:
            swaps.append((i, def_line[target]))

    # 从后往前换：前面的行号不受影响。
    # 做法是「把**定义行**搬到接口值前面」，而不是把接口值往后搬 —— 接口值那份初始化器
    # 必须出现在**所有**引用之后的位置上也无所谓，但它引用的那个 struct 必须先声明。
    for iface_i, def_i in sorted(swaps, reverse=True):
        def_line = lines[def_i]
        del lines[def_i]                 # 先摘掉定义行（它在接口值之后）
        lines.insert(iface_i, def_line)  # 再插到接口值那一行之前

    with open(path, 'w', encoding='utf-8', errors='replace') as fh:
        fh.write('\n'.join(lines))
    return len(swaps)


def main(argv):
    if len(argv) != 2:
        print('用法: win_fix_init_order.py <生成的 .c>', file=sys.stderr)
        return 2
    n = fix(argv[1])
    if n == 0:
        print('win_fix_init_order: 无需修补（生成物里的顺序已经正确）')
    else:
        print('win_fix_init_order: 已交换 %d 处初始化顺序' % n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
