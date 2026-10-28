#!/usr/bin/env python3
"""读 Mach-O 主可执行文件的 LC_MAIN.stacksize（主线程栈大小）。

用法：macho_stack.py <可执行文件> [最小字节数，可写 0x4000000]

为什么单拎一个脚本：macOS 的主线程栈不是 `ulimit -s` 能改的，它由 dyld 读
LC_MAIN.stacksize 决定（缺省 = 8 MB，arm64 是 8 MB、x86_64 也是 8 MB）。本仓
自测里有几处 MB 级的按值对象，8 MB 装不下（Linux 侧默认 ulimit -s 8192 跑
web/tui 组直接 rc=139），所以 `make macos` 链接时声明 64 MB。这条断言挡的是
「-Wl,-stack_size 没传下去」：产物照样能起，只是跑到 web/tui 组才 SIGSEGV，
而 macOS 客户机不留 DiagnosticReports（见 README.md §5），很难从一个 139 反查
回来。

只认 64 位小端 Mach-O（本仓 macOS 产物就是 x86_64 的 MH_EXECUTE）。
"""

import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_MAIN = 0x80000028
LC_UNIXTHREAD = 0x5
MIB = 1024 * 1024


def parse_size(text: str) -> int:
    text = text.strip().lower()
    if text.startswith("0x"):
        return int(text, 16)
    if text.endswith("m"):
        return int(float(text[:-1]) * MIB)
    return int(text, 10)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("用法: macho_stack.py <可执行文件> [最小字节数]", file=sys.stderr)
        return 2
    path = argv[1]
    want = parse_size(argv[2]) if len(argv) > 2 else 0x4000000
    with open(path, "rb") as fp:
        data = fp.read()
    if len(data) < 32:
        print(f"macho_stack: {path} 太短，不是 Mach-O", file=sys.stderr)
        return 1
    (magic, _cputype, _cpusub, filetype, ncmds, _sizeofcmds, _flags, _res) = (
        struct.unpack("<IiiIIIII", data[:32])
    )
    if magic != MH_MAGIC_64:
        print(f"macho_stack: {path} 不是 64 位小端 Mach-O"
              f"（magic=0x{magic:08x}）", file=sys.stderr)
        return 1
    if filetype != 0x2:  # MH_EXECUTE
        print(f"macho_stack: {path} 不是主可执行文件"
              f"（filetype={filetype}）", file=sys.stderr)
        return 1
    stack = -1
    off = 32
    seen = 0
    for _ in range(ncmds):
        if off + 8 > len(data):
            break
        cmd, size = struct.unpack("<II", data[off:off + 8])
        seen += 1
        if cmd == LC_MAIN and off + 24 <= len(data):
            _entry, stack = struct.unpack("<QQ", data[off + 8:off + 24])
        off += size
    if stack < 0:
        # 老式产物把入口和栈写在 LC_UNIXTHREAD 里；本仓不用那条路，只提示一下。
        print(f"macho_stack: {path} 没有 LC_MAIN（{seen} 个 load command），"
              "请确认是用 zig cc / clang 常规链接的")
        return 1
    shown = f"0x{stack:x}（{stack / MIB:.1f} MB）"
    if stack < want:
        print(f"macho_stack: 主线程栈只有 {shown}，需要 ≥ 0x{want:x}"
              f"（{want / MIB:.1f} MB）")
        return 1
    print(f"macho_stack: 通过（LC_MAIN.stacksize = {shown}，"
          f"门槛 0x{want:x}）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
