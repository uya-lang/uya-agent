#!/usr/bin/env python3
"""testdata/win_fix_nanosleep.py — `make windows` 的第 2 步之一（只改生成物）。

**为什么需要它**：`sys_nanosleep` 在 Linux 上的 ABI 是两个**指针**：

    export fn sys_nanosleep(req: &const TimeSpec, rem: &TimeSpec) !i32 {
        return @syscall(SYS_nanosleep, req as i64, rem as i64) as! i32;
    }

而编译器的 Windows 桥把它写成了**两个整数**：

    static struct err_union_int32_t uya_windows_nanosleep(int64_t req_sec, int64_t req_nsec) {
        int64_t ms = req_sec * 1000LL + req_nsec / 1000000LL;
        if (ms > 0) Sleep((DWORD)ms);

于是 `a1` 那个 `req` **指针**被当成「秒数」去乘 1000 —— 一个真实堆地址换算出来的
毫秒数是个天文数字，`Sleep()` 被截断成一到几十天的睡眠，进程**永久挂起**。

实测现场：dockur/windows 的 Win10 客户机里跑 `uya-agent.exe --selftest`，
日志停在 `selftest[sig-child-reset] SKIP` 之后（下一个是 `async-rt` 轮的
`rt_case_run`，它第一件事就是 `rt_sleep(150)`）—— 进程还在、CPU 不动、再也不出下一行，
看门狗 460 s 到点才杀掉。**这条比崩还难查**：没有 panic、没有退出码、什么都不打印。

**修法**：把桥里的那个函数换成按 `TimeSpec*` 读的版本（与 Linux ABI 一致），
`rem` 忽略（Linux 的 `rem` 也只在被信号打断时才有意义，而 Windows 没有信号）。

为什么修生成物：`nanosleep` 是 `extern "libc"` 的裸系统调用，源码里没有可绕的地方。
哪天编译器改对了，本脚本替换 0 处并退出 0。

用法：
    python3 testdata/win_fix_nanosleep.py <生成的 .c>
"""

import re
import sys

# 旧的（错的两个整数）实现，原样匹配后整体替换
OLD_RE = re.compile(
    r'static struct err_union_int32_t uya_windows_nanosleep\('
    r'int64_t req_sec, int64_t req_nsec\) \{\n'
    r'.*?\n\}\n',
    re.DOTALL,
)

NEW = r'''static struct err_union_int32_t uya_windows_nanosleep(int64_t req_ptr, int64_t rem_ptr) {
    /* req/rem 都是 `struct TimeSpec *`（见 testdata/win_fix_nanosleep.py）：
     * Linux 的 nanosleep ABI 传的是指针，而桥曾经把它当成 (sec, nsec) 两个整数 ——
     * 一个堆地址被当成秒数乘 1000 ⇒ Sleep 一个天文数字 ⇒ 进程静默挂死。 */
    const struct uya_windows_timespec_local {
        int64_t tv_sec;
        int64_t tv_nsec;
    } *req = (const struct uya_windows_timespec_local *)(intptr_t)req_ptr;
    (void)rem_ptr;
    if (req == (const struct uya_windows_timespec_local *)0) return uya_win_err_i32(22);
    {
        int64_t ms = req->tv_sec * 1000LL + req->tv_nsec / 1000000LL;
        if (ms > 0) Sleep((DWORD)ms);
    }
    return uya_win_ok_i32(0);
}
'''

ALREADY = 'uya_windows_timespec_local'


def fix(path):
    """把 nanosleep 桥换成按 TimeSpec* 读。返回 1 = 已替换，0 = 已经是对的。"""
    with open(path, encoding='utf-8', errors='replace') as fh:
        text = fh.read()
    if ALREADY in text:
        return 0
    new_text, n = OLD_RE.subn(NEW, text)
    if n == 0:
        # 生成物形状变了（编译器可能已经改对）：明确报出来，不静默跳过 ——
        # 静默跳过会让「进程静默挂死」这个最难的缺陷重新变成可能。
        raise SystemExit(
            'win_fix_nanosleep: 找不到旧的 uya_windows_nanosleep 实现，'
            '生成物形状变了（编译器更新？）—— 请确认 nanosleep 的 ABI 已按 '
            'TimeSpec* 生成')
    with open(path, 'w', encoding='utf-8', errors='replace') as fh:
        fh.write(new_text)
    return n


def main(argv):
    if len(argv) != 2:
        print('用法: win_fix_nanosleep.py <生成的 .c>', file=sys.stderr)
        return 2
    n = fix(argv[1])
    print('win_fix_nanosleep: %s' % (
        '已把 nanosleep 改成按 TimeSpec* 读（原来把指针当秒数 ⇒ 静默挂死）'
        if n else '无需修补（已经是对的）'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
