#!/usr/bin/env python3
"""给 uya 生成的 C 产物补 Darwin 的「同名 tag」避让。

## 为什么需要

uya 的 hosted 生成物自带一份最小 libc 类型：`struct timeval` / `struct sigaction`
/ `struct stat` / `struct timespec` …（`uya_part1_types.h` 里那一段）。Linux 上它们
和 glibc 不冲突（glibc 把真正的时间类型放在 `<sys/time.h>`，生成的产物并不 include
它）。Darwin 的 SDK 头则**顺手**就把 `sys/_types/_timeval.h` 带进来，于是同一份 TU
里出现两个 `struct timeval`：

    ./uya_part1_types.h:6894:8: error: redefinition of 'timeval'
    .../any-darwin-any/sys/_types/_timeval.h:34:1: note: previous definition …

`struct sigaction` / `struct stat` / `struct timespec` 同理。

## 怎么绕

编译器后续版本（0.11.0）的做法是把 **SDK 那一份**改名，让两边共存：在 include 系统
头**之前** `#define timeval uya_darwin_host_timeval_tag`，include 完再 `#undef`。
于是 SDK 里那个 tag 变成了另一个名字（布局还是 Darwin 的真布局），而 uya 自己用的
仍是自己的 `struct timeval`。本脚本对旧版编译器用文本复刻同一招：

* 只给**每一行 `#include <...>`** 前后加 `#define` / `#undef` 块 —— 改写区间只有
  那一行 include，不碰字符串字面量（词法改名做不到这点）；
* 幂等：产物里已经有 `UYA_DARWIN_HOST_RENAME` 标记就跳过；
* 只改**生成物**（`build/macos/uyacache`），源码与编译器一字不动。

用法：`fix_darwin_headers.py <生成物目录>`（递归处理 `*.h` / `*.c`）。

## 另一处：`uya_common.c` 里的弱引用钩子

生成物在 `uya_common.c` 里给「可选宿主入口」留了个钩子：

    extern int32_t uya_pipeline_worker_main_if_requested(void)
        __attribute__((weak));

ELF 里未定义的 weak 声明解析为 0，代码也照 0 判断，所以 Linux 上没事；Mach-O 没有
这个语义，ld 直接报

    error: undefined symbol: _uya_pipeline_worker_main_if_requested

编译器 0.11.0 已经为 `__APPLE__` 生成了 `dlsym(RTLD_DEFAULT, …)` 版本，旧版没有，
所以这里对旧版生成的产物做文本替换，换成同样的 dlsym 版本。
"""

import re
import sys
from pathlib import Path

MARKER = "UYA_DARWIN_HOST_RENAME"

# SDK 会定义、而 uya 生成物也自己定义的同名 tag / 函数名。
# timeval / sigaction / rusage 是 struct tag；signal / gettimeofday 是函数名（SDK 的
# 原型形参用 SDK 的 tag，两边原型会打架）。
# 注意**不要**列 stat / timespec：编译器自己已经用 uya_macos_native_* 避让过了
# （生成物里 `#define stat uya_macos_native_stat_call` 那一段），再改一次会互相
# 覆盖（实测报 'stat' macro redefined）。
RENAMES = ["timeval", "sigaction", "rusage", "signal", "gettimeofday"]

# 只包系统头（`#include <...>`）。包 `#include "..."` 会把工程头整段包进去 ——
# 那一段里的 `struct timeval {` 也会被改名，反而与 SDK 的定义撞车（实测）。
INCLUDE_RE = re.compile(r"^[ \t]*#[ \t]*include[ \t]*<", re.M)

# Darwin 的 `<signal.h>` 把 `sa_handler` / `sa_sigaction` 定义成**宏**
# （展开成 `__sigaction_u.__sa_handler`），会把 uya 自己那个 `struct sigaction`
# 的成员名改掉，所以 include 完必须 undef。
UNDEF_AFTER = ["sa_handler", "sa_sigaction"]


def wrap(text: str) -> str:
    out = []
    for line in text.splitlines(keepends=True):
        if not INCLUDE_RE.match(line):
            out.append(line)
            continue
        out.append("#ifdef __APPLE__\n")
        for name in RENAMES:
            out.append(f"#define {name} uya_darwin_host_{name}_tag\n")
        out.append("#endif\n")
        out.append(line)
        out.append("#ifdef __APPLE__\n")
        for name in RENAMES:
            out.append(f"#undef {name}\n")
        for name in UNDEF_AFTER:
            out.append(f"#undef {name}\n")
        out.append("#endif\n")
    return "".join(out)


HOOK_MARKER = "UYA_DARWIN_WEAK_HOOK"

# 编译器 0.10.4 生成的弱引用钩子（原文逐字）。
HOOK_OLD = """#if defined(__GNUC__) || defined(__clang__)
extern int32_t uya_pipeline_worker_main_if_requested(void) __attribute__((weak));
int32_t uya_pipeline_worker_dispatch(void) {
    if (uya_pipeline_worker_main_if_requested == (void *)0) return -1;
    return uya_pipeline_worker_main_if_requested();
}
"""

# 换成的版本：Darwin 走 dlsym（与编译器 0.11.0 为 __APPLE__ 生成的一致）。
HOOK_NEW = """#if defined(__APPLE__)
/* Mach-O 没有 ELF 的弱引用语义：未定义的 weak 声明照样是 undefined，
   只能在运行期查符号。见 testdata/macos/fix_darwin_headers.py。 */
#include <dlfcn.h>
typedef int32_t (*uya_pipeline_worker_fn)(void);
int32_t uya_pipeline_worker_dispatch(void) {
    static uya_pipeline_worker_fn real_fn = (uya_pipeline_worker_fn)0;
    static int32_t looked_up = 0;
    if (looked_up == 0) {
        real_fn = (uya_pipeline_worker_fn)dlsym(
            (void *)-2, "uya_pipeline_worker_main_if_requested");
        looked_up = 1;
    }
    if (real_fn == (uya_pipeline_worker_fn)0) return -1;
    return real_fn();
}
#elif defined(__GNUC__) || defined(__clang__)
extern int32_t uya_pipeline_worker_main_if_requested(void) __attribute__((weak));
int32_t uya_pipeline_worker_dispatch(void) {
    if (uya_pipeline_worker_main_if_requested == (void *)0) return -1;
    return uya_pipeline_worker_main_if_requested();
}
"""


def fix_pipeline_hook(root: Path) -> int:
    """把 uya_common.c 里的弱引用钩子换成 Darwin 可链接的 dlsym 版本。"""
    path = root / "uya_common.c"
    if not path.is_file():
        return 0
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    if HOOK_MARKER in text or HOOK_OLD not in text:
        return 0
    text = text.replace(HOOK_OLD, f"/* {HOOK_MARKER} */\n" + HOOK_NEW, 1)
    path.write_text(text, encoding="utf-8", errors="surrogateescape")
    return 1


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("用法: fix_darwin_headers.py <生成物目录>\n")
        return 2
    root = Path(argv[1])
    if not root.is_dir():
        sys.stderr.write(f"fix_darwin_headers: 目录不存在: {root}\n")
        return 2
    touched = 0
    for path in sorted(root.rglob("*")):
        if path.suffix not in (".h", ".c") or not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="surrogateescape")
        if MARKER in text:
            continue
        if not INCLUDE_RE.search(text):
            continue
        body = wrap(text)
        path.write_text(
            f"/* {MARKER}: 见 testdata/macos/fix_darwin_headers.py */\n" + body,
            encoding="utf-8",
            errors="surrogateescape",
        )
        touched += 1
    hook = fix_pipeline_hook(root)
    print(f"fix_darwin_headers: 处理 {touched} 个文件（{root}）, 钩子 {hook}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
